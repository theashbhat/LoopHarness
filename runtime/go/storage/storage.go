package storage

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// tsFormat stores timestamps with nanosecond precision so that the
// polling since-filter can distinguish events within the same second.
const tsFormat = time.RFC3339Nano

type Store struct {
	db *sql.DB
}

type Turn struct {
	ID            string          `json:"id"`
	CreatedAt     time.Time       `json:"created_at"`
	UpdatedAt     time.Time       `json:"updated_at"`
	Status        string          `json:"status"`
	MessagesJSON  json.RawMessage `json:"messages_json"`
	FinalResponse string          `json:"final_response"`
	Error         string          `json:"error,omitempty"`
	// UserID / ConversationID identify the device + chat that a turn belongs
	// to. They are only populated for async (handoff) turns — interactive SSE
	// turns leave them empty. UserID lets the completion path push back to the
	// originating device; ConversationID lets the client reconcile the reply
	// into the right conversation.
	UserID         string `json:"user_id,omitempty"`
	ConversationID string `json:"conversation_id,omitempty"`
}

type Job struct {
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

func New(dbPath string) (*Store, error) {
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("opening db: %w", err)
	}

	// Enable WAL for concurrent reads
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		return nil, fmt.Errorf("setting WAL: %w", err)
	}

	if err := migrate(db); err != nil {
		return nil, fmt.Errorf("migration: %w", err)
	}

	return &Store{db: db}, nil
}

func migrate(db *sql.DB) error {
	schema := `
	CREATE TABLE IF NOT EXISTS turns (
		id TEXT PRIMARY KEY,
		created_at TEXT NOT NULL,
		updated_at TEXT NOT NULL,
		status TEXT NOT NULL DEFAULT 'running',
		messages_json TEXT NOT NULL,
		final_response TEXT NOT NULL DEFAULT '',
		error TEXT NOT NULL DEFAULT ''
	);
	CREATE TABLE IF NOT EXISTS jobs (
		job_id TEXT PRIMARY KEY,
		turn_id TEXT NOT NULL,
		tool TEXT NOT NULL,
		args_json TEXT NOT NULL,
		status TEXT NOT NULL DEFAULT 'pending',
		result_json TEXT NOT NULL DEFAULT '',
		error TEXT NOT NULL DEFAULT '',
		created_at TEXT NOT NULL,
		updated_at TEXT NOT NULL,
		completed_at TEXT,
		FOREIGN KEY (turn_id) REFERENCES turns(id)
	);
	CREATE INDEX IF NOT EXISTS idx_turns_updated_at ON turns(updated_at);
	CREATE INDEX IF NOT EXISTS idx_jobs_updated_at ON jobs(updated_at);
	`
	if _, err := db.Exec(schema); err != nil {
		return err
	}

	// Additive column migrations for already-deployed DBs. CREATE TABLE IF NOT
	// EXISTS above never alters an existing table, so new columns must be added
	// explicitly. SQLite has no "ADD COLUMN IF NOT EXISTS", so we tolerate the
	// "duplicate column name" error to keep this idempotent.
	for _, stmt := range []string{
		"ALTER TABLE turns ADD COLUMN user_id TEXT NOT NULL DEFAULT ''",
		"ALTER TABLE turns ADD COLUMN conversation_id TEXT NOT NULL DEFAULT ''",
	} {
		if _, err := db.Exec(stmt); err != nil && !strings.Contains(err.Error(), "duplicate column name") {
			return err
		}
	}
	return nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) CreateTurn(id string, messagesJSON json.RawMessage, userID, conversationID string) error {
	now := time.Now().UTC().Format(tsFormat)
	_, err := s.db.Exec(
		"INSERT INTO turns (id, created_at, updated_at, status, messages_json, user_id, conversation_id) VALUES (?, ?, ?, 'running', ?, ?, ?)",
		id, now, now, string(messagesJSON), userID, conversationID,
	)
	return err
}

func (s *Store) CompleteTurn(id, finalResponse, errMsg string) error {
	status := "completed"
	if errMsg != "" {
		status = "error"
	}
	_, err := s.db.Exec(
		"UPDATE turns SET status = ?, final_response = ?, error = ?, updated_at = ? WHERE id = ?",
		status, finalResponse, errMsg, time.Now().UTC().Format(tsFormat), id,
	)
	return err
}

func (s *Store) GetTurn(id string) (*Turn, error) {
	row := s.db.QueryRow("SELECT id, created_at, updated_at, status, messages_json, final_response, error, user_id, conversation_id FROM turns WHERE id = ?", id)
	var t Turn
	var createdStr, updatedStr, messagesStr string
	if err := row.Scan(&t.ID, &createdStr, &updatedStr, &t.Status, &messagesStr, &t.FinalResponse, &t.Error, &t.UserID, &t.ConversationID); err != nil {
		return nil, fmt.Errorf("turn not found: %w", err)
	}
	t.CreatedAt, _ = time.Parse(tsFormat, createdStr)
	t.UpdatedAt, _ = time.Parse(tsFormat, updatedStr)
	t.MessagesJSON = json.RawMessage(messagesStr)
	return &t, nil
}

func (s *Store) CreateJob(jobID, turnID, tool string, argsJSON json.RawMessage) error {
	now := time.Now().UTC().Format(tsFormat)
	_, err := s.db.Exec(
		"INSERT INTO jobs (job_id, turn_id, tool, args_json, status, created_at, updated_at) VALUES (?, ?, ?, ?, 'pending', ?, ?)",
		jobID, turnID, tool, string(argsJSON), now, now,
	)
	return err
}

func (s *Store) CompleteJob(jobID string, resultJSON json.RawMessage, errMsg string) error {
	status := "completed"
	if errMsg != "" {
		status = "error"
	}
	now := time.Now().UTC().Format(tsFormat)
	_, err := s.db.Exec(
		"UPDATE jobs SET status = ?, result_json = ?, error = ?, completed_at = ?, updated_at = ? WHERE job_id = ?",
		status, string(resultJSON), errMsg, now, now, jobID,
	)
	return err
}

func (s *Store) TimeoutJob(jobID string) error {
	now := time.Now().UTC().Format(tsFormat)
	_, err := s.db.Exec(
		"UPDATE jobs SET status = 'timed_out', completed_at = ?, updated_at = ? WHERE job_id = ?",
		now, now, jobID,
	)
	return err
}

func (s *Store) GetJob(jobID string) (*Job, error) {
	row := s.db.QueryRow("SELECT job_id, turn_id, tool, args_json, status, result_json, error, created_at, updated_at, completed_at FROM jobs WHERE job_id = ?", jobID)
	var j Job
	var createdStr, updatedStr, argsStr, resultStr string
	var completedStr sql.NullString
	if err := row.Scan(&j.JobID, &j.TurnID, &j.Tool, &argsStr, &j.Status, &resultStr, &j.Error, &createdStr, &updatedStr, &completedStr); err != nil {
		return nil, fmt.Errorf("job not found: %w", err)
	}
	j.CreatedAt, _ = time.Parse(tsFormat, createdStr)
	j.UpdatedAt, _ = time.Parse(tsFormat, updatedStr)
	j.ArgsJSON = json.RawMessage(argsStr)
	j.ResultJSON = json.RawMessage(resultStr)
	if completedStr.Valid {
		t, _ := time.Parse(tsFormat, completedStr.String)
		j.CompletedAt = &t
	}
	return &j, nil
}

// ListTurns returns turns optionally filtered by since time and status,
// ordered by updated_at descending, capped at limit.
func (s *Store) ListTurns(since *time.Time, status string, limit int) ([]Turn, error) {
	query := "SELECT id, created_at, updated_at, status, final_response, error, conversation_id FROM turns WHERE 1=1"
	var args []interface{}
	if since != nil {
		query += " AND updated_at > ?"
		args = append(args, since.UTC().Format(tsFormat))
	}
	if status != "" {
		query += " AND status = ?"
		args = append(args, status)
	}
	query += " ORDER BY updated_at DESC LIMIT ?"
	args = append(args, limit)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("listing turns: %w", err)
	}
	defer rows.Close()

	var turns []Turn
	for rows.Next() {
		var t Turn
		var createdStr, updatedStr string
		if err := rows.Scan(&t.ID, &createdStr, &updatedStr, &t.Status, &t.FinalResponse, &t.Error, &t.ConversationID); err != nil {
			return nil, fmt.Errorf("scanning turn: %w", err)
		}
		t.CreatedAt, _ = time.Parse(tsFormat, createdStr)
		t.UpdatedAt, _ = time.Parse(tsFormat, updatedStr)
		turns = append(turns, t)
	}
	return turns, rows.Err()
}

// ListJobs returns jobs optionally filtered by since time and status,
// ordered by updated_at descending, capped at limit.
func (s *Store) ListJobs(since *time.Time, status string, limit int) ([]Job, error) {
	query := "SELECT job_id, turn_id, tool, args_json, status, result_json, error, created_at, updated_at, completed_at FROM jobs WHERE 1=1"
	var args []interface{}
	if since != nil {
		query += " AND updated_at > ?"
		args = append(args, since.UTC().Format(tsFormat))
	}
	if status != "" {
		query += " AND status = ?"
		args = append(args, status)
	}
	query += " ORDER BY updated_at DESC LIMIT ?"
	args = append(args, limit)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("listing jobs: %w", err)
	}
	defer rows.Close()

	var jobs []Job
	for rows.Next() {
		var j Job
		var createdStr, updatedStr, argsStr, resultStr string
		var completedStr sql.NullString
		if err := rows.Scan(&j.JobID, &j.TurnID, &j.Tool, &argsStr, &j.Status, &resultStr, &j.Error, &createdStr, &updatedStr, &completedStr); err != nil {
			return nil, fmt.Errorf("scanning job: %w", err)
		}
		j.CreatedAt, _ = time.Parse(tsFormat, createdStr)
		j.UpdatedAt, _ = time.Parse(tsFormat, updatedStr)
		j.ArgsJSON = json.RawMessage(argsStr)
		j.ResultJSON = json.RawMessage(resultStr)
		if completedStr.Valid {
			t, _ := time.Parse(tsFormat, completedStr.String)
			j.CompletedAt = &t
		}
		jobs = append(jobs, j)
	}
	return jobs, rows.Err()
}
