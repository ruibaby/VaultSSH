package main

import (
	"encoding/json"
	"os"
	"sync"
	"time"
)

type KeyInfo struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Type        string `json:"type"`
	Fingerprint string `json:"fingerprint"`
	PublicKey   string `json:"publicKey"`
}

type Status struct {
	Phase     string    `json:"phase,omitempty"`
	Warnings  []string  `json:"warnings,omitempty"`
	State     string    `json:"state"`
	PID       int       `json:"pid,omitempty"`
	Socket    string    `json:"socket,omitempty"`
	Keys      []KeyInfo `json:"keys,omitempty"`
	Error     string    `json:"error,omitempty"`
	UpdatedAt string    `json:"updatedAt"`
}

type StatusWriter struct {
	notify func(Status)
	path   string
	mu     sync.Mutex
}

func NewStatusWriter(path string) *StatusWriter {
	return &StatusWriter{path: path}
}

func (w *StatusWriter) Write(s Status) {
	s.UpdatedAt = time.Now().Format(time.RFC3339Nano)
	if w.notify != nil {
		w.notify(s)
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	tmp := w.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0600); err != nil {
		return
	}
	_ = os.Rename(tmp, w.path)
}
