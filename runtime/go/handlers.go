package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/getathelas/LoopHarness/runtime/go/agent"
	"github.com/getathelas/LoopHarness/runtime/go/bridge"
	"github.com/getathelas/LoopHarness/runtime/go/storage"
)

func authMiddleware(secret string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") || strings.TrimPrefix(auth, "Bearer ") != secret {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// POST /turn
func handleTurn(ag *agent.Agent, store *storage.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Messages       []agent.Message `json:"messages"`
			ConversationID string          `json:"conversation_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusBadRequest)
			return
		}
		if len(req.Messages) == 0 {
			http.Error(w, `{"error":"messages required"}`, http.StatusBadRequest)
			return
		}

		// Stream response via SSE
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, `{"error":"streaming not supported"}`, http.StatusInternalServerError)
			return
		}

		turnID, err := ag.RunTurn(r.Context(), req.Messages, req.ConversationID, func(token string) {
			fmt.Fprintf(w, "data: %s\n\n", token)
			flusher.Flush()
		})
		if err != nil {
			fmt.Fprintf(w, "event: error\ndata: %s\n\n", err.Error())
			flusher.Flush()
			return
		}
		fmt.Fprintf(w, "event: done\ndata: {\"turn_id\":%q}\n\n", turnID)
		flusher.Flush()
	}
}

// POST /result
func handleResult(brg *bridge.Bridge) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			JobID  string          `json:"job_id"`
			Result json.RawMessage `json:"result"`
			Error  string          `json:"error"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusBadRequest)
			return
		}
		if req.JobID == "" {
			http.Error(w, `{"error":"job_id required"}`, http.StatusBadRequest)
			return
		}

		brg.ResolveResult(req.JobID, bridge.Result{
			Data:  req.Result,
			Error: req.Error,
		})
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"ok":true}`))
	}
}

// GET /turn/{id}
func handleGetTurn(store *storage.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		turn, err := store.GetTurn(id)
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(turn)
	}
}

// GET /job/{job_id}
func handleGetJob(store *storage.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		jobID := r.PathValue("job_id")
		job, err := store.GetJob(jobID)
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(job)
	}
}

func parsePollParams(r *http.Request) (since *time.Time, status string, limit int) {
	limit = 20
	if s := r.URL.Query().Get("since"); s != "" {
		if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
			since = &t
		} else if t, err := time.Parse(time.RFC3339, s); err == nil {
			since = &t
		}
	}
	status = r.URL.Query().Get("status")
	if l := r.URL.Query().Get("limit"); l != "" {
		if n, err := strconv.Atoi(l); err == nil && n > 0 {
			limit = n
		}
	}
	if limit > 100 {
		limit = 100
	}
	return
}

type turnPollItem struct {
	ID            string    `json:"id"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
	Status        string    `json:"status"`
	FinalResponse string    `json:"final_response"`
	Error         string    `json:"error,omitempty"`
}

type jobPollItem struct {
	JobID       string          `json:"job_id"`
	TurnID      string          `json:"turn_id"`
	Tool        string          `json:"tool"`
	ArgsJSON    json.RawMessage `json:"args_json"`
	Status      string          `json:"status"`
	ResultJSON  json.RawMessage `json:"result_json,omitempty"`
	Error       string          `json:"error,omitempty"`
	CreatedAt   time.Time       `json:"created_at"`
	UpdatedAt   time.Time       `json:"updated_at"`
	CompletedAt *time.Time      `json:"completed_at,omitempty"`
}

// GET /turns
func handleListTurns(store *storage.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		since, status, limit := parsePollParams(r)
		turns, err := store.ListTurns(since, status, limit)
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusInternalServerError)
			return
		}
		items := make([]turnPollItem, len(turns))
		for i, t := range turns {
			items[i] = turnPollItem{
				ID:            t.ID,
				CreatedAt:     t.CreatedAt,
				UpdatedAt:     t.UpdatedAt,
				Status:        t.Status,
				FinalResponse: t.FinalResponse,
				Error:         t.Error,
			}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"turns":       items,
			"server_time": time.Now().UTC().Format(time.RFC3339Nano),
		})
	}
}

// GET /jobs
func handleListJobs(store *storage.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		since, status, limit := parsePollParams(r)
		jobs, err := store.ListJobs(since, status, limit)
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusInternalServerError)
			return
		}
		items := make([]jobPollItem, len(jobs))
		for i, j := range jobs {
			items[i] = jobPollItem{
				JobID:       j.JobID,
				TurnID:      j.TurnID,
				Tool:        j.Tool,
				ArgsJSON:    j.ArgsJSON,
				Status:      j.Status,
				ResultJSON:  j.ResultJSON,
				Error:       j.Error,
				CreatedAt:   j.CreatedAt,
				UpdatedAt:   j.UpdatedAt,
				CompletedAt: j.CompletedAt,
			}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"jobs":        items,
			"server_time": time.Now().UTC().Format(time.RFC3339Nano),
		})
	}
}
