package registry_test

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/getathelas/LoopHarness/runtime/go/bridge"
	"github.com/getathelas/LoopHarness/runtime/go/registry"
)

func TestLocalRouting(t *testing.T) {
	brg := bridge.NewStubbed()
	reg := registry.New(brg)

	called := false
	reg.RegisterLocal("test_tool", func(_ context.Context, args json.RawMessage) (json.RawMessage, error) {
		called = true
		return json.RawMessage(`{"ok":true}`), nil
	})

	tag, ok := reg.GetTag("test_tool")
	if !ok {
		t.Fatal("tool not found")
	}
	if tag != registry.Local {
		t.Fatalf("expected Local tag, got %d", tag)
	}

	result, err := reg.Dispatch(context.Background(), "job-1", "test_tool", json.RawMessage(`{}`))
	if err != nil {
		t.Fatalf("dispatch error: %v", err)
	}
	if !called {
		t.Fatal("local tool was not called")
	}

	var res map[string]bool
	json.Unmarshal(result, &res)
	if !res["ok"] {
		t.Fatal("unexpected result")
	}
}

func TestDeviceRouting(t *testing.T) {
	brg := bridge.NewStubbed()
	reg := registry.New(brg)

	reg.RegisterDevice("device_tool")

	tag, ok := reg.GetTag("device_tool")
	if !ok {
		t.Fatal("tool not found")
	}
	if tag != registry.Device {
		t.Fatalf("expected Device tag, got %d", tag)
	}
}

func TestUnknownTool(t *testing.T) {
	brg := bridge.NewStubbed()
	reg := registry.New(brg)

	_, err := reg.Dispatch(context.Background(), "job-1", "nonexistent", json.RawMessage(`{}`))
	if err == nil {
		t.Fatal("expected error for unknown tool")
	}
}
