package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/getathelas/LoopHarness/runtime/go/agent"
	"github.com/getathelas/LoopHarness/runtime/go/bridge"
	"github.com/getathelas/LoopHarness/runtime/go/registry"
	"github.com/getathelas/LoopHarness/runtime/go/storage"
	localtools "github.com/getathelas/LoopHarness/runtime/go/tools/local"
)

// mockLLM returns a single tool call to echo, then a final message.
type mockLLM struct {
	callCount int
}

func (m *mockLLM) ChatCompletionStream(_ context.Context, messages []agent.Message, tools []agent.ToolDef) (*agent.StreamReader, error) {
	m.callCount++

	if m.callCount == 1 {
		// First call: return a tool call to echo
		sseData := `data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"echo","arguments":"{\"text\":\"hello world\"}"}}]}}]}

data: [DONE]

`
		return agent.NewStreamReaderFromReader(io.NopCloser(strings.NewReader(sseData))), nil
	}

	// Second call: return final content
	sseData := `data: {"choices":[{"delta":{"content":"Echo result: hello world"}}]}

data: [DONE]

`
	return agent.NewStreamReaderFromReader(io.NopCloser(strings.NewReader(sseData))), nil
}

func TestIntegrationEchoRoundTrip(t *testing.T) {
	// Setup storage with temp file
	dbPath := fmt.Sprintf("/tmp/loop_test_%d.db", time.Now().UnixNano())
	defer os.Remove(dbPath)

	store, err := storage.New(dbPath)
	if err != nil {
		t.Fatalf("storage: %v", err)
	}
	defer store.Close()

	// Setup bridge (stubbed)
	brg := bridge.NewStubbed()

	// Setup registry with local tools
	reg := registry.New(brg)
	localtools.Register(reg)

	// Setup agent with mock LLM
	mock := &mockLLM{}
	ag := agent.NewWithClient(mock, reg, store)

	// Setup HTTP server
	secret := "test-secret"
	startTime := time.Now()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"ok":true,"version":"test","uptime_seconds":%.0f}`, time.Since(startTime).Seconds())
	})
	mux.HandleFunc("POST /turn", authMiddleware(secret, handleTurn(ag, store)))
	mux.HandleFunc("GET /turn/{id}", authMiddleware(secret, handleGetTurn(store)))
	mux.HandleFunc("GET /job/{job_id}", authMiddleware(secret, handleGetJob(store)))

	srv := httptest.NewServer(mux)
	defer srv.Close()

	// Test health endpoint (no auth)
	resp, err := http.Get(srv.URL + "/health")
	if err != nil {
		t.Fatalf("health request: %v", err)
	}
	if resp.StatusCode != 200 {
		t.Fatalf("health status: %d", resp.StatusCode)
	}

	// Test turn endpoint
	turnBody, _ := json.Marshal(map[string]interface{}{
		"messages": []map[string]string{
			{"role": "user", "content": "Say hello"},
		},
	})
	req, _ := http.NewRequest("POST", srv.URL+"/turn", bytes.NewReader(turnBody))
	req.Header.Set("Authorization", "Bearer "+secret)
	req.Header.Set("Content-Type", "application/json")

	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("turn request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("turn status: %d, body: %s", resp.StatusCode, body)
	}

	// Read SSE stream
	body, _ := io.ReadAll(resp.Body)
	bodyStr := string(body)

	if !strings.Contains(bodyStr, "Echo result: hello world") {
		t.Fatalf("expected echo result in stream, got: %s", bodyStr)
	}
	if !strings.Contains(bodyStr, "event: done") {
		t.Fatalf("expected done event in stream, got: %s", bodyStr)
	}

	// Verify the turn was persisted — extract turn_id from the done event
	var turnID string
	for _, line := range strings.Split(bodyStr, "\n") {
		if strings.HasPrefix(line, "data: {\"turn_id\"") {
			var doneData struct {
				TurnID string `json:"turn_id"`
			}
			json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &doneData)
			turnID = doneData.TurnID
			break
		}
	}
	if turnID == "" {
		t.Fatalf("no turn_id found in stream output: %s", bodyStr)
	}

	// Fetch the turn via the HTTP endpoint
	req, _ = http.NewRequest("GET", srv.URL+"/turn/"+turnID, nil)
	req.Header.Set("Authorization", "Bearer "+secret)
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("get turn: %v", err)
	}
	if resp.StatusCode != 200 {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("get turn status: %d, body: %s, turnID: %s", resp.StatusCode, respBody, turnID)
	}

	// Verify auth rejection
	req, _ = http.NewRequest("POST", srv.URL+"/turn", bytes.NewReader(turnBody))
	req.Header.Set("Authorization", "Bearer wrong-secret")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("auth test request: %v", err)
	}
	if resp.StatusCode != 401 {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}
