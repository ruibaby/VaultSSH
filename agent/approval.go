package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sync"
	"time"
)

type ApprovalRequest struct {
	ID               string `json:"id"`
	Created          string `json:"created"`
	ExpiresAt        string `json:"expiresAt"`
	PID              int    `json:"pid"`
	Process          string `json:"process"`
	Executable       string `json:"executable"`
	ParentPID        int    `json:"parentPid,omitempty"`
	ParentProcess    string `json:"parentProcess,omitempty"`
	ParentExecutable string `json:"parentExecutable,omitempty"`
	KeyName          string `json:"keyName"`
	Fingerprint      string `json:"fingerprint"`
}

type approvalDecision struct {
	ID           string `json:"id"`
	Allow        bool   `json:"allow"`
	GraceSeconds int    `json:"graceSeconds"`
}

type Approver struct {
	timeout    time.Duration
	emit       func(ControlEvent) error
	mu         sync.Mutex
	cache      map[string]time.Time
	pending    map[string]chan approvalDecision
	closed     bool
	generation uint64
}

func NewApprover(timeout time.Duration, emit func(ControlEvent) error) *Approver {
	if timeout <= 0 {
		timeout = 60 * time.Second
	}
	return &Approver{timeout: timeout, emit: emit, cache: make(map[string]time.Time), pending: make(map[string]chan approvalDecision)}
}

// Only the inherited control pipe calls Decide. Files and SSH clients cannot
// submit decisions. Never keep the cache lock while waiting for the user.
func (a *Approver) Decide(d approvalDecision) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if ch := a.pending[d.ID]; ch != nil {
		select {
		case ch <- d:
		default:
		}
	}
}

func (a *Approver) Revoke() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.revokeLocked()
}

func (a *Approver) revokeLocked() {
	a.generation++
	clear(a.cache)
	for id, ch := range a.pending {
		select {
		case ch <- approvalDecision{ID: id}:
		default:
		}
	}
}

func (a *Approver) Close() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.closed = true
	a.revokeLocked()
}

func (a *Approver) Approve(peer PeerInfo, key *Key) (bool, string) {
	if a == nil || a.emit == nil {
		return false, "unavailable"
	}
	expires := time.Now().Add(a.timeout)
	scope := approvalScope(peer, key)
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return false, "closed"
	}
	for key, until := range a.cache {
		if !time.Now().Before(until) {
			delete(a.cache, key)
		}
	}
	if scope != "" && time.Now().Before(a.cache[scope]) {
		a.mu.Unlock()
		return true, "cached"
	}
	if len(a.pending) >= 32 {
		a.mu.Unlock()
		return false, "busy"
	}
	id, err := randomID()
	if err != nil {
		a.mu.Unlock()
		return false, "create_failed"
	}
	ch := make(chan approvalDecision, 1)
	a.pending[id] = ch
	generation := a.generation
	a.mu.Unlock()
	defer func() {
		a.mu.Lock()
		delete(a.pending, id)
		a.mu.Unlock()
		_ = a.emit(ControlEvent{Type: "dismiss", ID: id})
	}()
	req := ApprovalRequest{ID: id, Created: time.Now().Format(time.RFC3339Nano), ExpiresAt: expires.Format(time.RFC3339Nano), PID: peer.PID, Process: peer.Process, Executable: peer.Executable, ParentPID: peer.ParentPID, ParentProcess: peer.ParentProcess, ParentExecutable: peer.ParentExecutable, KeyName: key.Name, Fingerprint: key.Fingerprint}
	if err := a.emit(ControlEvent{Type: "approval", Request: &req}); err != nil {
		return false, "send_failed"
	}
	timer := time.NewTimer(time.Until(expires))
	defer timer.Stop()
	select {
	case <-timer.C:
		return false, "timeout"
	case decision := <-ch:
		a.mu.Lock()
		defer a.mu.Unlock()
		if a.closed || generation != a.generation {
			return false, "revoked"
		}
		if !time.Now().Before(expires) {
			return false, "expired"
		}
		if !decision.Allow {
			return false, "denied"
		}
		// The UI supports once or five minutes; don't accept longer grants.
		seconds := min(max(decision.GraceSeconds, 0), 300)
		if scope != "" && seconds > 0 {
			a.cache[scope] = time.Now().Add(time.Duration(seconds) * time.Second)
		}
		return true, "allowed"
	}
}

func approvalScope(peer PeerInfo, key *Key) string {
	// Unknown identities must never share cached approval (including PID 0).
	if peer.Executable == "" || peer.ParentExecutable == "" {
		return ""
	}
	return peer.Executable + "\x00" + peer.ParentExecutable + "\x00" + key.Fingerprint
}

func randomID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

var errControlClosed = errors.New("control channel closed")
