package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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
func cacheUntil(a *Approver, peer PeerInfo) time.Time {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.cache[approvalScope(peer, testApprovalKey())]
}

func TestDefaultGraceWindowIsFiveMinutes(t *testing.T) {
	a, _ := testApprover(time.Second)
	if a.graceSeconds != 300 {
		t.Fatalf("default grace = %d, want 300", a.graceSeconds)
	}
}

func TestConfiguredWindowCachesForThirtyMinutes(t *testing.T) {
	a, events := testApprover(time.Second)
	if got := a.SetGraceWindow(1800); got != 1800 {
		t.Fatalf("applied = %d", got)
	}
	done := approveAsync(a, testPeer())
	req := nextRequest(t, events)
	a.Decide(approvalDecision{ID: req.ID, Allow: true, GraceSeconds: 1800})
	if !<-done {
		t.Fatal("denied")
	}
	remaining := time.Until(cacheUntil(a, testPeer()))
	if remaining < 29*time.Minute || remaining > 30*time.Minute {
		t.Fatalf("cached for %v, want about 30 minutes", remaining)
	}
	ok, reason := a.Approve(testPeer(), testApprovalKey())
	seconds, err := strconv.Atoi(strings.TrimPrefix(reason, "cached:"))
	if !ok || err != nil || seconds < 1795 || seconds > 1800 {
		t.Fatalf("second request = %v %q, want cached with about 1800 seconds left", ok, reason)
	}
}

func TestCachedLogUsesRemainingLifetime(t *testing.T) {
	a, events := testApprover(time.Second)
	a.SetGraceWindow(1800)
	done := approveAsync(a, testPeer())
	req := nextRequest(t, events)
	a.Decide(approvalDecision{ID: req.ID, Allow: true, GraceSeconds: 1800})
	if !<-done {
		t.Fatal("denied")
	}
	// Widening the configured window must not relabel the existing 30-minute
	// grant as a fresh 60-minute one.
	a.SetGraceWindow(3600)
	until := cacheUntil(a, testPeer())
	remaining := time.Until(until)
	ok, reason := a.Approve(testPeer(), testApprovalKey())
	if !ok {
		t.Fatal("cache miss")
	}
	seconds, err := strconv.Atoi(strings.TrimPrefix(reason, "cached:"))
	if err != nil {
		t.Fatalf("reason = %q: %v", reason, err)
	}
	// The value is the actual remaining lifetime, truncated to whole seconds.
	if seconds < 1795 || seconds > 1800 {
		t.Fatalf("cached seconds = %d, remaining = %v; want about 1800, not the 3600 window", seconds, remaining)
	}
	if seconds > int(remaining/time.Second)+1 {
		t.Fatalf("cached seconds = %d, remaining = %v", seconds, remaining)
	}
	detail := approvalMessage(reason)
	want := fmt.Sprintf("Cached approval is valid for %d seconds", seconds)
	if seconds%60 == 0 {
		want = fmt.Sprintf("Cached approval is valid for %d minutes", seconds/60)
	}
	if detail != want {
		t.Fatalf("detail = %q, want %q", detail, want)
	}
	t.Logf("remaining=%v reason=%q detail=%q", remaining, reason, detail)
}

func TestInvalidGraceWindowsAreRejected(t *testing.T) {
	a, _ := testApprover(time.Second)
	if got := a.SetGraceWindow(1800); got != 1800 {
		t.Fatalf("applied = %d", got)
	}
	for _, value := range []int{-1, 0, 1, 301, 3599, 3601, 86400} {
		if got := a.SetGraceWindow(value); got != 1800 {
			t.Fatalf("accepted invalid window %d as %d", value, got)
		}
	}
	if got := a.SetGraceWindow(3600); got != 3600 {
		t.Fatalf("rejected hard maximum: %d", got)
	}
}

func TestDecisionCannotExceedConfiguredWindow(t *testing.T) {
	for _, tc := range []struct {
		window   int
		decision int
	}{
		{1800, 999999},
		{300, 1800},
		{3600, 3600},
	} {
		a, events := testApprover(time.Second)
		a.SetGraceWindow(tc.window)
		done := approveAsync(a, testPeer())
		req := nextRequest(t, events)
		a.Decide(approvalDecision{ID: req.ID, Allow: true, GraceSeconds: tc.decision})
		if !<-done {
			t.Fatal("denied")
		}
		remaining := time.Until(cacheUntil(a, testPeer()))
		limit := time.Duration(tc.window) * time.Second
		if remaining > limit+time.Second || remaining < limit-2*time.Second {
			t.Fatalf("window %d decision %d cached for %v", tc.window, tc.decision, remaining)
		}
	}
}

func TestShorteningWindowTrimsExistingGrants(t *testing.T) {
	a, events := testApprover(time.Second)
	a.SetGraceWindow(3600)
	done := approveAsync(a, testPeer())
	req := nextRequest(t, events)
	a.Decide(approvalDecision{ID: req.ID, Allow: true, GraceSeconds: 3600})
	if !<-done {
		t.Fatal("denied")
	}
	a.SetGraceWindow(300)
	remaining := time.Until(cacheUntil(a, testPeer()))
	if remaining > 300*time.Second+time.Second || remaining < 299*time.Second {
		t.Fatalf("grant kept for %v after shortening to 5 minutes", remaining)
	}
}

func TestLongWindowDoesNotCacheInterpreters(t *testing.T) {
	peer := testPeer()
	peer.Executable = "/usr/bin/python3"
	a, events := testApprover(time.Second)
	a.SetGraceWindow(3600)
	for i := 0; i < 2; i++ {
		done := approveAsync(a, peer)
		req := nextRequest(t, events)
		if req.CacheAllowed {
			t.Fatal("cache offered for interpreter")
		}
		a.Decide(approvalDecision{ID: req.ID, Allow: true, GraceSeconds: 3600})
		if !<-done {
			t.Fatal("denied")
		}
	}
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
