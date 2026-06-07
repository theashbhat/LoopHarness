package main

import (
	"encoding/json"
	"fmt"
	"os"
)

// Config holds all runtime configuration loaded from config.json.
type Config struct {
	APNsKeyPath    string `json:"apns_key_path"`
	APNsKeyID      string `json:"apns_key_id"`
	APNsTeamID     string `json:"apns_team_id"`
	APNsBundleID   string `json:"apns_bundle_id"`
	DevicePushToken string `json:"device_push_token"`
	ModelAPIKey    string `json:"model_api_key"`
	SharedSecret   string `json:"shared_secret"`
	ListenPort     int    `json:"listen_port"`

	// PushSendURL is the central push backend endpoint the runner POSTs to when
	// an async (handoff) turn completes, so the originating device gets an APNs
	// alert. Defaults to the loopharness push service when unset.
	PushSendURL string `json:"push_send_url"`
}

func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config %s: %w", path, err)
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing config: %w", err)
	}
	if cfg.ListenPort == 0 {
		cfg.ListenPort = 8080
	}
	if cfg.PushSendURL == "" {
		cfg.PushSendURL = "https://dev.generalbackend.com/loopharness/push/send"
	}
	return &cfg, nil
}
