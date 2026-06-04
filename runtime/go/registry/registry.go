package registry

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"

	"github.com/getathelas/LoopHarness/runtime/go/bridge"
)

// Tag determines where a tool executes.
type Tag int

const (
	Local  Tag = iota // Runs in-process on the VM
	Device            // Proxied to device via APNs bridge
)

// ToolFunc is the signature for a local tool implementation.
type ToolFunc func(ctx context.Context, args json.RawMessage) (json.RawMessage, error)

type toolEntry struct {
	Tag  Tag
	Func ToolFunc // nil for Device tools
}

// Registry routes tool calls to either local implementations or the device bridge.
type Registry struct {
	mu    sync.RWMutex
	tools map[string]toolEntry
	brg   *bridge.Bridge
}

func New(brg *bridge.Bridge) *Registry {
	return &Registry{
		tools: make(map[string]toolEntry),
		brg:   brg,
	}
}

func (r *Registry) RegisterLocal(name string, fn ToolFunc) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.tools[name] = toolEntry{Tag: Local, Func: fn}
}

func (r *Registry) RegisterDevice(name string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.tools[name] = toolEntry{Tag: Device, Func: nil}
}

// Dispatch executes the named tool, routing to local or device as appropriate.
func (r *Registry) Dispatch(ctx context.Context, jobID, name string, args json.RawMessage) (json.RawMessage, error) {
	r.mu.RLock()
	entry, ok := r.tools[name]
	r.mu.RUnlock()

	if !ok {
		return nil, fmt.Errorf("unknown tool: %s", name)
	}

	switch entry.Tag {
	case Local:
		return entry.Func(ctx, args)
	case Device:
		return r.brg.CallDevice(ctx, jobID, name, args)
	default:
		return nil, fmt.Errorf("invalid tag for tool %s", name)
	}
}

// GetTag returns the routing tag for a tool. Used in tests.
func (r *Registry) GetTag(name string) (Tag, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	entry, ok := r.tools[name]
	if !ok {
		return 0, false
	}
	return entry.Tag, true
}
