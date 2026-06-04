package bridge_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/getathelas/LoopHarness/runtime/go/bridge"
)

// fakeAPNs records pushes and optionally fails.
type fakeAPNs struct {
	pushes  [][]byte
	failErr error
}

func (f *fakeAPNs) SendPush(deviceToken string, payload []byte) error {
	if f.failErr != nil {
		return f.failErr
	}
	f.pushes = append(f.pushes, payload)
	return nil
}

func TestResultFanIn(t *testing.T) {
	fake := &fakeAPNs{}
	brg := bridge.NewWithClient(fake, "test-device-token")

	ctx := context.Background()
	done := make(chan struct{})
	var result json.RawMessage
	var callErr error

	go func() {
		result, callErr = brg.CallDevice(ctx, "job-123", "read_calendar", json.RawMessage(`{}`))
		close(done)
	}()

	// Give goroutine time to start and register pending job
	time.Sleep(50 * time.Millisecond)

	// Simulate device responding
	brg.ResolveResult("job-123", bridge.Result{
		Data: json.RawMessage(`{"events":["meeting"]}`),
	})

	<-done
	if callErr != nil {
		t.Fatalf("unexpected error: %v", callErr)
	}
	if string(result) != `{"events":["meeting"]}` {
		t.Fatalf("unexpected result: %s", result)
	}
	if len(fake.pushes) != 1 {
		t.Fatalf("expected 1 push, got %d", len(fake.pushes))
	}
}

func TestTimeout(t *testing.T) {
	fake := &fakeAPNs{}
	brg := bridge.NewWithClient(fake, "test-device-token")

	// Use a very short context timeout to test the timeout path
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	_, err := brg.CallDevice(ctx, "job-timeout", "read_calendar", json.RawMessage(`{}`))
	if err == nil {
		t.Fatal("expected timeout error")
	}
}

func TestResolveUnknownJob(t *testing.T) {
	brg := bridge.NewStubbed()
	// Should not panic
	brg.ResolveResult("nonexistent-job", bridge.Result{Data: json.RawMessage(`{}`)})
}

func TestErrorResult(t *testing.T) {
	fake := &fakeAPNs{}
	brg := bridge.NewWithClient(fake, "test-device-token")

	ctx := context.Background()
	done := make(chan struct{})
	var callErr error

	go func() {
		_, callErr = brg.CallDevice(ctx, "job-err", "read_calendar", json.RawMessage(`{}`))
		close(done)
	}()

	time.Sleep(50 * time.Millisecond)

	brg.ResolveResult("job-err", bridge.Result{
		Error: "calendar access denied",
	})

	<-done
	if callErr == nil {
		t.Fatal("expected error")
	}
	if callErr.Error() != "device error: calendar access denied" {
		t.Fatalf("unexpected error message: %v", callErr)
	}
}
