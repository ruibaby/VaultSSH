package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type Event struct {
	Time          string `json:"time"`
	Type          string `json:"type"`
	PID           int    `json:"pid,omitempty"`
	Process       string `json:"process,omitempty"`
	Executable    string `json:"executable,omitempty"`
	ParentPID     int    `json:"parentPid,omitempty"`
	ParentProcess string `json:"parentProcess,omitempty"`
	KeyName       string `json:"keyName,omitempty"`
	Fingerprint   string `json:"fingerprint,omitempty"`
	Result        string `json:"result,omitempty"`
	Reason        string `json:"reason,omitempty"`
	Detail        string `json:"detail,omitempty"`
}

type EventLogger struct {
	notify func(Event)
	mu     sync.Mutex
	f      *os.File
}

func NewEventLogger(path string) *EventLogger {
	_ = os.MkdirAll(filepath.Dir(path), 0700)
	if st, err := os.Stat(path); err == nil && st.Size() > 5<<20 {
		_ = os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return &EventLogger{}
	}
	return &EventLogger{f: f}
}

func (l *EventLogger) Event(ev Event) {
	if l == nil {
		return
	}
	if ev.Time == "" {
		ev.Time = time.Now().Format(time.RFC3339Nano)
	}
	if l.notify != nil {
		l.notify(ev)
	}
	if l.f == nil {
		return
	}
	b, err := json.Marshal(ev)
	if err != nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	_, _ = l.f.Write(append(b, '\n'))
}

func (l *EventLogger) Close() {
	if l != nil && l.f != nil {
		_ = l.f.Close()
	}
}
