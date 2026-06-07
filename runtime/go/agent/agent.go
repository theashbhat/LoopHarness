package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"

	"github.com/getathelas/LoopHarness/runtime/go/registry"
	"github.com/getathelas/LoopHarness/runtime/go/storage"
)

// Message matches the OpenAI chat message format.
type Message struct {
	Role       string     `json:"role"`
	Content    string     `json:"content,omitempty"`
	ToolCalls  []ToolCall `json:"tool_calls,omitempty"`
	ToolCallID string     `json:"tool_call_id,omitempty"`
}

type ToolCall struct {
	ID       string       `json:"id"`
	Type     string       `json:"type"`
	Function FunctionCall `json:"function"`
}

type FunctionCall struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

// LLMClient is the interface for calling the model. Allows mocking in tests.
type LLMClient interface {
	ChatCompletionStream(ctx context.Context, messages []Message, tools []ToolDef) (*StreamReader, error)
}

// ToolDef describes a tool for the OpenAI API.
type ToolDef struct {
	Type     string         `json:"type"`
	Function ToolDefFunction `json:"function"`
}

type ToolDefFunction struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters"`
}

// Agent orchestrates the turn loop.
type Agent struct {
	client   LLMClient
	registry *registry.Registry
	store    *storage.Store
	tools    []ToolDef
}

func New(apiKey string, reg *registry.Registry, store *storage.Store) *Agent {
	return &Agent{
		client:   &openAIClient{apiKey: apiKey},
		registry: reg,
		store:    store,
		tools:    buildToolDefs(),
	}
}

// NewWithClient creates an agent with a custom LLM client (for testing).
func NewWithClient(client LLMClient, reg *registry.Registry, store *storage.Store) *Agent {
	return &Agent{
		client:   client,
		registry: reg,
		store:    store,
		tools:    buildToolDefs(),
	}
}

func buildToolDefs() []ToolDef {
	return []ToolDef{
		{
			Type: "function",
			Function: ToolDefFunction{
				Name:        "echo",
				Description: "Returns the input text unchanged.",
				Parameters:  json.RawMessage(`{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}`),
			},
		},
		{
			Type: "function",
			Function: ToolDefFunction{
				Name:        "web_fetch",
				Description: "Performs an HTTP GET and returns the response body (capped at 64KB).",
				Parameters:  json.RawMessage(`{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}`),
			},
		},
		{
			Type: "function",
			Function: ToolDefFunction{
				Name:        "read_calendar",
				Description: "Reads calendar events from the user's device.",
				Parameters:  json.RawMessage(`{"type":"object","properties":{}}`),
			},
		},
	}
}

// PrepareTurn creates and persists a turn without running it, returning the new
// turn id. The async (handoff) path uses this to return the id to the client
// immediately, then runs the loop in the background via RunPreparedTurn.
// userID / conversationID are persisted with the turn (empty for interactive
// turns) so the async completion path can push back to the originating device.
func (a *Agent) PrepareTurn(messages []Message, userID, conversationID string) (string, error) {
	turnID := newID()
	messagesJSON, _ := json.Marshal(messages)
	if err := a.store.CreateTurn(turnID, messagesJSON, userID, conversationID); err != nil {
		return "", fmt.Errorf("persisting turn: %w", err)
	}
	return turnID, nil
}

// RunTurn executes a full agent turn: call LLM, dispatch tools, repeat until final message.
func (a *Agent) RunTurn(ctx context.Context, messages []Message, userID, conversationID string, streamFn func(string)) (string, error) {
	turnID, err := a.PrepareTurn(messages, userID, conversationID)
	if err != nil {
		return "", err
	}
	if err := a.RunPreparedTurn(ctx, turnID, messages, streamFn); err != nil {
		return "", err
	}
	return turnID, nil
}

// RunPreparedTurn runs the agent loop for an already-created turn (see
// PrepareTurn). It drives the turn to completion and records the result in
// storage. Callers that ran PrepareTurn in a request handler can invoke this
// in a goroutine with a detached context so the turn survives client disconnect.
func (a *Agent) RunPreparedTurn(ctx context.Context, turnID string, messages []Message, streamFn func(string)) error {
	// The agent loop: call LLM, handle tool calls, repeat
	for {
		reader, err := a.client.ChatCompletionStream(ctx, messages, a.tools)
		if err != nil {
			a.store.CompleteTurn(turnID, "", err.Error())
			return fmt.Errorf("llm call: %w", err)
		}

		msg, err := reader.Collect(streamFn)
		if err != nil {
			a.store.CompleteTurn(turnID, "", err.Error())
			return fmt.Errorf("reading stream: %w", err)
		}

		// If no tool calls, this is the final response
		if len(msg.ToolCalls) == 0 {
			a.store.CompleteTurn(turnID, msg.Content, "")
			return nil
		}

		// Dispatch tool calls in parallel
		messages = append(messages, *msg)
		toolResults := make([]Message, len(msg.ToolCalls))
		var wg sync.WaitGroup
		var mu sync.Mutex
		var firstErr error

		for i, tc := range msg.ToolCalls {
			wg.Add(1)
			go func(idx int, call ToolCall) {
				defer wg.Done()

				jobID := newID()
				argsJSON := json.RawMessage(call.Function.Arguments)

				a.store.CreateJob(jobID, turnID, call.Function.Name, argsJSON)

				result, err := a.registry.Dispatch(ctx, jobID, call.Function.Name, argsJSON)

				if err != nil {
					// Check if timeout for device calls
					if err.Error() == fmt.Sprintf("device call timed out after %s", "30s") {
						a.store.TimeoutJob(jobID)
					} else {
						a.store.CompleteJob(jobID, nil, err.Error())
					}
					mu.Lock()
					if firstErr == nil {
						firstErr = err
					}
					toolResults[idx] = Message{
						Role:       "tool",
						Content:    fmt.Sprintf(`{"error":%q}`, err.Error()),
						ToolCallID: call.ID,
					}
					mu.Unlock()
					return
				}

				a.store.CompleteJob(jobID, result, "")
				mu.Lock()
				toolResults[idx] = Message{
					Role:       "tool",
					Content:    string(result),
					ToolCallID: call.ID,
				}
				mu.Unlock()
			}(i, tc)
		}
		wg.Wait()

		messages = append(messages, toolResults...)
	}
}

// --- OpenAI streaming client ---

type openAIClient struct {
	apiKey string
}

type StreamReader struct {
	body   io.ReadCloser
	reader *bufio.Reader
}

func (c *openAIClient) ChatCompletionStream(ctx context.Context, messages []Message, tools []ToolDef) (*StreamReader, error) {
	reqBody := map[string]interface{}{
		"model":    "gpt-4o",
		"messages": messages,
		"stream":   true,
	}
	if len(tools) > 0 {
		reqBody["tools"] = tools
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("marshaling request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", "https://api.openai.com/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.apiKey)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("calling openai: %w", err)
	}
	if resp.StatusCode != 200 {
		respBody, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return nil, fmt.Errorf("openai returned %d: %s", resp.StatusCode, string(respBody))
	}

	return &StreamReader{
		body:   resp.Body,
		reader: bufio.NewReader(resp.Body),
	}, nil
}

// Collect reads the SSE stream, calls streamFn for each content token,
// and returns the fully assembled message (including tool calls).
func (sr *StreamReader) Collect(streamFn func(string)) (*Message, error) {
	defer sr.body.Close()

	var content string
	var toolCalls []ToolCall
	toolCallArgs := make(map[int]*bytes.Buffer) // index -> accumulated args

	for {
		line, err := sr.reader.ReadBytes('\n')
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("reading stream: %w", err)
		}

		line = bytes.TrimSpace(line)
		if !bytes.HasPrefix(line, []byte("data: ")) {
			continue
		}
		data := bytes.TrimPrefix(line, []byte("data: "))
		if string(data) == "[DONE]" {
			break
		}

		var chunk streamChunk
		if err := json.Unmarshal(data, &chunk); err != nil {
			continue
		}

		if len(chunk.Choices) == 0 {
			continue
		}

		delta := chunk.Choices[0].Delta

		if delta.Content != "" {
			content += delta.Content
			if streamFn != nil {
				streamFn(delta.Content)
			}
		}

		for _, tc := range delta.ToolCalls {
			// Grow toolCalls slice as needed
			for len(toolCalls) <= tc.Index {
				toolCalls = append(toolCalls, ToolCall{Type: "function"})
			}
			if tc.ID != "" {
				toolCalls[tc.Index].ID = tc.ID
			}
			if tc.Function.Name != "" {
				toolCalls[tc.Index].Function.Name = tc.Function.Name
			}
			if tc.Function.Arguments != "" {
				if _, ok := toolCallArgs[tc.Index]; !ok {
					toolCallArgs[tc.Index] = &bytes.Buffer{}
				}
				toolCallArgs[tc.Index].WriteString(tc.Function.Arguments)
			}
		}
	}

	// Assemble final tool call arguments
	for i, buf := range toolCallArgs {
		if i < len(toolCalls) {
			toolCalls[i].Function.Arguments = buf.String()
		}
	}

	msg := &Message{
		Role:      "assistant",
		Content:   content,
		ToolCalls: toolCalls,
	}
	return msg, nil
}

type streamChunk struct {
	Choices []streamChoice `json:"choices"`
}

type streamChoice struct {
	Delta streamDelta `json:"delta"`
}

type streamDelta struct {
	Content   string            `json:"content"`
	ToolCalls []streamToolCall  `json:"tool_calls"`
}

type streamToolCall struct {
	Index    int          `json:"index"`
	ID       string       `json:"id"`
	Function FunctionCall `json:"function"`
}
