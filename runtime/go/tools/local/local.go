package local

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"github.com/getathelas/LoopHarness/runtime/go/registry"
)

const maxFetchBody = 64 * 1024 // 64KB

// Register adds all local tool implementations to the registry.
func Register(reg *registry.Registry) {
	reg.RegisterLocal("echo", echoTool)
	reg.RegisterLocal("web_fetch", webFetchTool)
}

func echoTool(_ context.Context, args json.RawMessage) (json.RawMessage, error) {
	var params struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(args, &params); err != nil {
		return nil, fmt.Errorf("parsing echo args: %w", err)
	}
	result, _ := json.Marshal(map[string]string{"text": params.Text})
	return result, nil
}

func webFetchTool(ctx context.Context, args json.RawMessage) (json.RawMessage, error) {
	var params struct {
		URL string `json:"url"`
	}
	if err := json.Unmarshal(args, &params); err != nil {
		return nil, fmt.Errorf("parsing web_fetch args: %w", err)
	}
	if params.URL == "" {
		return nil, fmt.Errorf("url is required")
	}

	req, err := http.NewRequestWithContext(ctx, "GET", params.URL, nil)
	if err != nil {
		return nil, fmt.Errorf("creating request: %w", err)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetching %s: %w", params.URL, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxFetchBody))
	if err != nil {
		return nil, fmt.Errorf("reading response: %w", err)
	}

	result, _ := json.Marshal(map[string]interface{}{
		"status": resp.StatusCode,
		"body":   string(body),
	})
	return result, nil
}
