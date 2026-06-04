package device

import "github.com/getathelas/LoopHarness/runtime/go/registry"

// Register adds all device tool stubs to the registry.
// These tools have no local implementation; calls are routed through the bridge.
func Register(reg *registry.Registry) {
	reg.RegisterDevice("read_calendar")
}
