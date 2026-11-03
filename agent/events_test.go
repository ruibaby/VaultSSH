package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestEventLogRotatesDuringRun(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	logger := NewEventLogger(path)
	defer logger.Close()
	// Multiple rotations without restarting the logger.
	for i := 0; i < 15; i++ {
		logger.Event(Event{Type: "test", Detail: strings.Repeat("x", 1<<20)})
	}
	for _, name := range []string{path, path + ".1"} {
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		if len(data) == 0 || len(data) > maxEventLogSize {
			t.Fatalf("unexpected log size: %d", len(data))
		}
		for _, line := range bytes.Split(bytes.TrimSpace(data), []byte{'\n'}) {
			if !json.Valid(line) {
				t.Fatal("rotation split a JSON event")
			}
		}
		info, _ := os.Stat(name)
		if info.Mode().Perm() != 0600 {
			t.Fatalf("log permissions: %o", info.Mode().Perm())
		}
	}
}

func TestEventLogOversizeAndClose(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	logger := NewEventLogger(path)
	notifications := 0
	logger.notify = func(Event) { notifications++ }
	logger.Event(Event{Detail: strings.Repeat("x", maxEventLogSize)})
	if notifications != 1 {
		t.Fatal("oversized event did not reach UI")
	}
	logger.notify = nil
	var group sync.WaitGroup
	for i := 0; i < 10; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			logger.Event(Event{Type: "test"})
		}()
	}
	logger.Close()
	group.Wait()
	logger.Close()
	logger.Event(Event{Type: "after-close"})
	info, _ := os.Stat(path)
	if info.Size() >= maxEventLogSize {
		t.Fatal("oversized event persisted")
	}
}
