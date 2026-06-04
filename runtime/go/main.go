package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/getathelas/LoopHarness/runtime/go/agent"
	"github.com/getathelas/LoopHarness/runtime/go/bridge"
	"github.com/getathelas/LoopHarness/runtime/go/registry"
	"github.com/getathelas/LoopHarness/runtime/go/storage"
	localtools "github.com/getathelas/LoopHarness/runtime/go/tools/local"
	devicetools "github.com/getathelas/LoopHarness/runtime/go/tools/device"
)

var version = "0.1.0"

func main() {
	configPath := flag.String("config", "config.json", "path to config.json")
	flag.Parse()

	cfg, err := LoadConfig(*configPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	// Storage
	store, err := storage.New("loop_runner.db")
	if err != nil {
		log.Fatalf("storage: %v", err)
	}
	defer store.Close()

	// Bridge
	var brg *bridge.Bridge
	if cfg.APNsKeyPath != "" {
		brg, err = bridge.New(cfg.APNsKeyPath, cfg.APNsKeyID, cfg.APNsTeamID, cfg.APNsBundleID, cfg.DevicePushToken)
		if err != nil {
			log.Fatalf("bridge: %v", err)
		}
	} else {
		log.Println("push stubbed: apns_key_path not configured")
		brg = bridge.NewStubbed()
	}

	// Registry
	reg := registry.New(brg)
	localtools.Register(reg)
	devicetools.Register(reg)

	// Agent
	ag := agent.New(cfg.ModelAPIKey, reg, store)

	// HTTP server
	startTime := time.Now()
	mux := http.NewServeMux()

	// Health (no auth)
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"ok":true,"version":%q,"uptime_seconds":%.0f}`, version, time.Since(startTime).Seconds())
	})

	// Auth-protected endpoints
	mux.HandleFunc("POST /turn", authMiddleware(cfg.SharedSecret, handleTurn(ag, store)))
	mux.HandleFunc("POST /result", authMiddleware(cfg.SharedSecret, handleResult(brg)))
	mux.HandleFunc("GET /turn/{id}", authMiddleware(cfg.SharedSecret, handleGetTurn(store)))
	mux.HandleFunc("GET /job/{job_id}", authMiddleware(cfg.SharedSecret, handleGetJob(store)))
	mux.HandleFunc("GET /turns", authMiddleware(cfg.SharedSecret, handleListTurns(store)))
	mux.HandleFunc("GET /jobs", authMiddleware(cfg.SharedSecret, handleListJobs(store)))

	addr := fmt.Sprintf(":%d", cfg.ListenPort)
	srv := &http.Server{Addr: addr, Handler: mux}

	go func() {
		log.Printf("loop-runner %s listening on %s", version, addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server: %v", err)
		}
	}()

	// Graceful shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	log.Println("shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	srv.Shutdown(ctx)
}
