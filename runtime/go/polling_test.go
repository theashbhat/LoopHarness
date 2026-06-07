package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/getathelas/LoopHarness/runtime/go/storage"
)

func setupPollingTest(t *testing.T) (*storage.Store, *httptest.Server, func()) {
	t.Helper()
	dbPath := fmt.Sprintf("/tmp/loop_poll_test_%d.db", time.Now().UnixNano())

	store, err := storage.New(dbPath)
	if err != nil {
		t.Fatalf("storage: %v", err)
	}

	secret := "test-secret"
	mux := http.NewServeMux()
	mux.HandleFunc("GET /turns", authMiddleware(secret, handleListTurns(store)))
	mux.HandleFunc("GET /jobs", authMiddleware(secret, handleListJobs(store)))
	srv := httptest.NewServer(mux)

	cleanup := func() {
		srv.Close()
		store.Close()
		os.Remove(dbPath)
	}
	return store, srv, cleanup
}

func doGet(t *testing.T, srv *httptest.Server, path string) map[string]json.RawMessage {
	t.Helper()
	req, _ := http.NewRequest("GET", srv.URL+path, nil)
	req.Header.Set("Authorization", "Bearer test-secret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request %s: %v", path, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status %d for %s: %s", resp.StatusCode, path, body)
	}
	var result map[string]json.RawMessage
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
	return result
}

func TestPollTurnsSinceFilter(t *testing.T) {
	store, srv, cleanup := setupPollingTest(t)
	defer cleanup()

	// Insert turns at staggered timestamps
	store.CreateTurn("t1", json.RawMessage(`[{"role":"user","content":"a"}]`), "", "")
	time.Sleep(10 * time.Millisecond)
	midpoint := time.Now().UTC()
	time.Sleep(10 * time.Millisecond)
	store.CreateTurn("t2", json.RawMessage(`[{"role":"user","content":"b"}]`), "", "")
	time.Sleep(10 * time.Millisecond)
	store.CreateTurn("t3", json.RawMessage(`[{"role":"user","content":"c"}]`), "", "")

	// Poll without since — should return all 3
	result := doGet(t, srv, "/turns")
	var allTurns []json.RawMessage
	json.Unmarshal(result["turns"], &allTurns)
	if len(allTurns) != 3 {
		t.Fatalf("expected 3 turns, got %d", len(allTurns))
	}

	// Poll with since=midpoint — should return only t2 and t3
	sinceStr := midpoint.Format(time.RFC3339Nano)
	result = doGet(t, srv, "/turns?since="+sinceStr)
	var newTurns []json.RawMessage
	json.Unmarshal(result["turns"], &newTurns)
	if len(newTurns) != 2 {
		t.Fatalf("expected 2 turns after since, got %d", len(newTurns))
	}

	// Verify server_time is present
	if _, ok := result["server_time"]; !ok {
		t.Fatal("missing server_time in response")
	}
}

func TestPollTurnsStatusFilter(t *testing.T) {
	store, srv, cleanup := setupPollingTest(t)
	defer cleanup()

	store.CreateTurn("t1", json.RawMessage(`[]`), "", "")
	store.CreateTurn("t2", json.RawMessage(`[]`), "", "")
	store.CreateTurn("t3", json.RawMessage(`[]`), "", "")

	store.CompleteTurn("t1", "done", "")
	store.CompleteTurn("t2", "", "oops")

	// Filter status=completed
	result := doGet(t, srv, "/turns?status=completed")
	var turns []json.RawMessage
	json.Unmarshal(result["turns"], &turns)
	if len(turns) != 1 {
		t.Fatalf("expected 1 completed turn, got %d", len(turns))
	}

	// Filter status=error
	result = doGet(t, srv, "/turns?status=error")
	json.Unmarshal(result["turns"], &turns)
	if len(turns) != 1 {
		t.Fatalf("expected 1 error turn, got %d", len(turns))
	}

	// Filter status=running
	result = doGet(t, srv, "/turns?status=running")
	json.Unmarshal(result["turns"], &turns)
	if len(turns) != 1 {
		t.Fatalf("expected 1 running turn, got %d", len(turns))
	}
}

func TestPollServerTimeMonotonic(t *testing.T) {
	_, srv, cleanup := setupPollingTest(t)
	defer cleanup()

	// First poll: get server_time
	result1 := doGet(t, srv, "/turns")
	var st1 string
	json.Unmarshal(result1["server_time"], &st1)
	t1, err := time.Parse(time.RFC3339Nano, st1)
	if err != nil {
		t.Fatalf("parse server_time: %v", err)
	}

	time.Sleep(10 * time.Millisecond)

	// Second poll: use previous server_time as since
	result2 := doGet(t, srv, "/turns?since="+st1)
	var st2 string
	json.Unmarshal(result2["server_time"], &st2)
	t2, err := time.Parse(time.RFC3339Nano, st2)
	if err != nil {
		t.Fatalf("parse server_time: %v", err)
	}

	if !t2.After(t1) {
		t.Fatalf("server_time not monotonic: %s >= %s", st1, st2)
	}
}

func TestPollTurnsLimit(t *testing.T) {
	store, srv, cleanup := setupPollingTest(t)
	defer cleanup()

	for i := 0; i < 5; i++ {
		store.CreateTurn(fmt.Sprintf("t%d", i), json.RawMessage(`[]`), "", "")
	}

	result := doGet(t, srv, "/turns?limit=2")
	var turns []json.RawMessage
	json.Unmarshal(result["turns"], &turns)
	if len(turns) != 2 {
		t.Fatalf("expected 2 turns with limit=2, got %d", len(turns))
	}
}

func TestPollJobsSinceFilter(t *testing.T) {
	store, srv, cleanup := setupPollingTest(t)
	defer cleanup()

	store.CreateTurn("t1", json.RawMessage(`[]`), "", "")

	store.CreateJob("j1", "t1", "echo", json.RawMessage(`{"text":"a"}`))
	time.Sleep(10 * time.Millisecond)
	midpoint := time.Now().UTC()
	time.Sleep(10 * time.Millisecond)
	store.CreateJob("j2", "t1", "echo", json.RawMessage(`{"text":"b"}`))

	// All jobs
	result := doGet(t, srv, "/jobs")
	var allJobs []json.RawMessage
	json.Unmarshal(result["jobs"], &allJobs)
	if len(allJobs) != 2 {
		t.Fatalf("expected 2 jobs, got %d", len(allJobs))
	}

	// Since filter
	sinceStr := midpoint.Format(time.RFC3339Nano)
	result = doGet(t, srv, "/jobs?since="+sinceStr)
	var newJobs []json.RawMessage
	json.Unmarshal(result["jobs"], &newJobs)
	if len(newJobs) != 1 {
		t.Fatalf("expected 1 job after since, got %d", len(newJobs))
	}
}

func TestPollJobsStatusFilter(t *testing.T) {
	store, srv, cleanup := setupPollingTest(t)
	defer cleanup()

	store.CreateTurn("t1", json.RawMessage(`[]`), "", "")
	store.CreateJob("j1", "t1", "echo", json.RawMessage(`{}`))
	store.CreateJob("j2", "t1", "echo", json.RawMessage(`{}`))
	store.CreateJob("j3", "t1", "echo", json.RawMessage(`{}`))

	store.CompleteJob("j1", json.RawMessage(`{"ok":true}`), "")
	store.CompleteJob("j2", nil, "fail")

	// Filter status=completed
	result := doGet(t, srv, "/jobs?status=completed")
	var jobs []json.RawMessage
	json.Unmarshal(result["jobs"], &jobs)
	if len(jobs) != 1 {
		t.Fatalf("expected 1 completed job, got %d", len(jobs))
	}

	// Filter status=pending
	result = doGet(t, srv, "/jobs?status=pending")
	json.Unmarshal(result["jobs"], &jobs)
	if len(jobs) != 1 {
		t.Fatalf("expected 1 pending job, got %d", len(jobs))
	}
}

func TestPollTurnsAuth(t *testing.T) {
	_, srv, cleanup := setupPollingTest(t)
	defer cleanup()

	req, _ := http.NewRequest("GET", srv.URL+"/turns", nil)
	req.Header.Set("Authorization", "Bearer wrong")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	if resp.StatusCode != 401 {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}
