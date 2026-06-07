package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
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
		// An empty shared_secret disables auth — convenient for a single-user
		// runner reached only over a private SSH tunnel (no public exposure).
		if secret != "" {
			auth := r.Header.Get("Authorization")
			if !strings.HasPrefix(auth, "Bearer ") || strings.TrimPrefix(auth, "Bearer ") != secret {
				http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
				return
			}
		}
		next(w, r)
	}
}

// POST /turn
func handleTurn(ag *agent.Agent, store *storage.Store, pushSendURL string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Messages       []agent.Message `json:"messages"`
			ConversationID string          `json:"conversation_id"`
			UserID         string          `json:"user_id"`
			Async          bool            `json:"async"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusBadRequest)
			return
		}
		if len(req.Messages) == 0 {
			http.Error(w, `{"error":"messages required"}`, http.StatusBadRequest)
			return
		}

		// Async (handoff) mode: persist the turn, return its id immediately, and
		// run the agent loop in the background. The client (a backgrounding iOS
		// app) disconnects right after the 202, so the loop MUST use a detached
		// context — r.Context() is cancelled on disconnect. On completion we push
		// an APNs alert back to the originating device via the central backend.
		if req.Async {
			turnID, err := ag.PrepareTurn(req.Messages, req.UserID, req.ConversationID)
			if err != nil {
				http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusAccepted)
			fmt.Fprintf(w, `{"id":%q}`, turnID)

			go func() {
				runErr := ag.RunPreparedTurn(context.Background(), turnID, req.Messages, nil)
				if runErr != nil {
					log.Printf("async turn %s failed: %v", turnID, runErr)
				}
				sendCompletionPush(pushSendURL, store, turnID)
			}()
			return
		}

		// Interactive mode: stream the response via SSE.
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, `{"error":"streaming not supported"}`, http.StatusInternalServerError)
			return
		}

		turnID, err := ag.RunTurn(r.Context(), req.Messages, req.UserID, req.ConversationID, func(token string) {
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

// sendCompletionPush notifies the originating device that an async turn finished.
// It reads the completed turn (for user_id, conversation_id, and the response
// text) and POSTs an alert to the central push backend, targeting the user. A
// turn with no user_id (interactive turn) is skipped. Best-effort: failures are
// logged, not surfaced.
func sendCompletionPush(pushSendURL string, store *storage.Store, turnID string) {
	if pushSendURL == "" {
		return
	}
	turn, err := store.GetTurn(turnID)
	if err != nil {
		log.Printf("completion push: turn %s not found: %v", turnID, err)
		return
	}
	if turn.UserID == "" {
		return // interactive turn — nobody to push to
	}

	title := "Loop"
	body := truncate(turn.FinalResponse, 180)
	if turn.Error != "" {
		body = "Your agent hit an error finishing this reply."
	} else if body == "" {
		body = "Your agent finished."
	}

	payload := map[string]interface{}{
		"user_id": turn.UserID,
		"title":   title,
		"body":    body,
		"data": map[string]interface{}{
			"type":            "runner_turn",
			"turn_id":         turn.ID,
			"conversation_id": turn.ConversationID,
		},
	}
	bodyJSON, err := json.Marshal(payload)
	if err != nil {
		log.Printf("completion push: marshal: %v", err)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "POST", pushSendURL, bytes.NewReader(bodyJSON))
	if err != nil {
		log.Printf("completion push: new request: %v", err)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Printf("completion push: POST %s: %v", pushSendURL, err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		log.Printf("completion push: backend returned %d for turn %s", resp.StatusCode, turnID)
	}
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
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
	ID             string    `json:"id"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
	Status         string    `json:"status"`
	FinalResponse  string    `json:"final_response"`
	Error          string    `json:"error,omitempty"`
	ConversationID string    `json:"conversation_id,omitempty"`
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
				ID:             t.ID,
				CreatedAt:      t.CreatedAt,
				UpdatedAt:      t.UpdatedAt,
				Status:         t.Status,
				FinalResponse:  t.FinalResponse,
				Error:          t.Error,
				ConversationID: t.ConversationID,
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
