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
	path   string
	size   int64
}

const maxEventLogSize = 5 << 20

func NewEventLogger(path string) *EventLogger {
	_ = os.MkdirAll(filepath.Dir(path), 0700)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return &EventLogger{}
	}
	l := &EventLogger{f: f, path: path}
	if st, err := f.Stat(); err == nil {
		l.size = st.Size()
	}
	return l
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
	b, err := json.Marshal(ev)
	if err != nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f == nil {
		return
	}
	b = append(b, '\n')
	// Keep at most two bounded files even when the helper runs for weeks.
	// Oversized events still reach the UI, but are not persisted.
	if len(b) > maxEventLogSize {
		return
	}
	if l.size+int64(len(b)) > maxEventLogSize {
		if err := os.Rename(l.path, l.path+".1"); err != nil {
			return
		}
		_ = l.f.Close()
		l.f, err = os.OpenFile(l.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
		l.size = 0
		if err != nil {
			return
		}
	}
	n, _ := l.f.Write(b)
	l.size += int64(n)
}

func (l *EventLogger) Close() {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f != nil {
		_ = l.f.Close()
		l.f = nil
	}
}
