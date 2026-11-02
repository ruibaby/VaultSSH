package main

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func testPeer() PeerInfo {
	return PeerInfo{PID: 100, Process: "ssh", Executable: "/usr/bin/ssh", ParentPID: 90, ParentProcess: "git", ParentExecutable: "/usr/bin/git"}
}
func testApprovalKey() *Key { return &Key{ID: "test", Name: "test-key", Fingerprint: "SHA256:test"} }
func testApprover(timeout time.Duration) (*Approver, chan ControlEvent) {
	events := make(chan ControlEvent, 128)
	return NewApprover(timeout, func(e ControlEvent) error { events <- e; return nil }), events
}
func nextRequest(t *testing.T, events <-chan ControlEvent) ApprovalRequest {
	t.Helper()
	timer := time.NewTimer(time.Second)
	defer timer.Stop()
	for {
		select {
		case e := <-events:
			if e.Request != nil {
				return *e.Request
			}
		case <-timer.C:
			t.Fatal("missing approval request")
			return ApprovalRequest{}
		}
	}
}
func approveAsync(a *Approver, p PeerInfo) <-chan bool {
	done := make(chan bool, 1)
	go func() { ok, _ := a.Approve(p, testApprovalKey()); done <- ok }()
	return done
}
func TestApproverTimeoutFailsClosed(t *testing.T) {
	a, _ := testApprover(40 * time.Millisecond)
	if ok, _ := a.Approve(testPeer(), testApprovalKey()); ok {
		t.Fatal("timeout allowed")
	}
	if ok, _ := (*Approver)(nil).Approve(testPeer(), testApprovalKey()); ok {
		t.Fatal("missing channel allowed")
	}
}
func TestApproverCachesAndRevokes(t *testing.T) {
	a, events := testApprover(time.Second)
	done := approveAsync(a, testPeer())
	req := nextRequest(t, events)
	a.Decide(approvalDecision{ID: req.ID, Allow: true, GraceSeconds: 300})
	if !<-done {
		t.Fatal("denied")
	}
	if ok, _ := a.Approve(testPeer(), testApprovalKey()); !ok {
		t.Fatal("cache missing")
	}
	a.Revoke()
	done = approveAsync(a, testPeer())
	req = nextRequest(t, events)
	a.Decide(approvalDecision{ID: req.ID, Allow: false})
	if <-done {
		t.Fatal("revoke did not clear cache")
	}
}
func TestOnceAndDenialAreNotCached(t *testing.T) {
	for _, allow := range []bool{true, false} {
		a, events := testApprover(time.Second)
		for i := 0; i < 2; i++ {
			done := approveAsync(a, testPeer())
			req := nextRequest(t, events)
			a.Decide(approvalDecision{ID: req.ID, Allow: allow})
			if got := <-done; got != allow {
				t.Fatalf("got %v", got)
			}
		}
	}
}
func TestCachedCallerDoesNotWaitForOtherPrompt(t *testing.T) {
	a, events := testApprover(time.Second)
	a.cache[approvalScope(testPeer(), testApprovalKey())] = time.Now().Add(time.Minute)
	other := testPeer()
	other.Executable = "/other"
	pending := approveAsync(a, other)
	nextRequest(t, events)
	done := approveAsync(a, testPeer())
	select {
	case ok := <-done:
		if !ok {
			t.Fatal("cached request denied")
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatal("cache blocked by prompt")
	}
	a.Close()
	if <-pending {
		t.Fatal("closed request allowed")
	}
}
func TestConcurrentRequestsExpireTogether(t *testing.T) {
	a, events := testApprover(100 * time.Millisecond)
	first := approveAsync(a, testPeer())
	nextRequest(t, events)
	second := approveAsync(a, testPeer())
	nextRequest(t, events)
	start := time.Now()
	if <-first || <-second {
		t.Fatal("unanswered requests allowed")
	}
	if time.Since(start) > 170*time.Millisecond {
		t.Fatal("timeouts were serialized")
	}
}
func TestUnknownIdentityDoesNotCache(t *testing.T) {
	a, events := testApprover(time.Second)
	for i := 0; i < 2; i++ {
		done := approveAsync(a, PeerInfo{})
		req := nextRequest(t, events)
		a.Decide(approvalDecision{ID: req.ID, Allow: true, GraceSeconds: 300})
		if !<-done {
			t.Fatal("denied")
		}
	}
}
func TestDecisionFilesCannotAuthorize(t *testing.T) {
	a, events := testApprover(100 * time.Millisecond)
	done := approveAsync(a, testPeer())
	req := nextRequest(t, events)
	b, _ := json.Marshal(approvalDecision{ID: req.ID, Allow: true, GraceSeconds: 300})
	if err := os.WriteFile(filepath.Join(t.TempDir(), "approval-decision.json"), b, 0600); err != nil {
		t.Fatal(err)
	}
	if <-done {
		t.Fatal("filesystem decision accepted")
	}
}
func TestWrongDecisionIDAndClosedChannel(t *testing.T) {
	a, events := testApprover(time.Second)
	done := approveAsync(a, testPeer())
	nextRequest(t, events)
	a.Decide(approvalDecision{ID: "wrong", Allow: true})
	select {
	case <-done:
		t.Fatal("wrong ID consumed")
	case <-time.After(10 * time.Millisecond):
	}
	a.Close()
	if <-done {
		t.Fatal("close allowed pending request")
	}
	if ok, _ := a.Approve(testPeer(), testApprovalKey()); ok {
		t.Fatal("close allowed new request")
	}
}
func TestControlEOFRevokesPendingAndCached(t *testing.T) {
	r, w := io.Pipe()
	defer r.Close()
	cancelled := make(chan struct{})
	c := NewControlChannel(r, io.Discard, func() { close(cancelled) })
	a, events := testApprover(time.Second)
	a.cache["old"] = time.Now().Add(time.Hour)
	go c.ReadCommands(a, NewAgent())
	pending := approveAsync(a, testPeer())
	nextRequest(t, events)
	w.Close()
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("EOF not propagated")
	}
	if <-pending {
		t.Fatal("EOF allowed pending request")
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if len(a.cache) != 0 {
		t.Fatal("EOF retained grants")
	}
}
