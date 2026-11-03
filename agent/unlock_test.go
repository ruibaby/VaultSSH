package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"golang.org/x/crypto/ssh"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func loadedTestAgent(t *testing.T) *Agent {
	t.Helper()
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(key)
	if err != nil {
		t.Fatal(err)
	}
	a := NewAgent()
	a.SetKeys([]*Key{testKey("test", "disposable", signer)})
	return a
}

func TestLockedRequestsCoalesceAndRequireExplicitUnlock(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	events := make(chan ControlEvent, 64)
	target := NewAgent()
	loaded := loadedTestAgent(t)
	var calls atomic.Int32
	g := NewUnlockGate(ctx, target, func(e ControlEvent) error { events <- e; return nil }, func(context.Context, string) (*Agent, error) { calls.Add(1); return loaded, nil })
	results := make(chan bool, 16)
	for i := 0; i < 16; i++ {
		go func() { results <- g.Wait(testPeer()) }()
	}
	req := nextRequest(t, events)
	g.Unlock("test", "wrong-id")
	if calls.Load() != 0 || len(target.Keys()) != 0 {
		t.Fatal("socket request/wrong ID loaded keys")
	}
	g.Unlock("test", req.ID)
	for i := 0; i < 16; i++ {
		select {
		case ok := <-results:
			if !ok {
				t.Fatal("unlock failed")
			}
		case <-time.After(time.Second):
			t.Fatal("request did not resume")
		}
	}
	if calls.Load() != 1 || len(target.Keys()) != 1 {
		t.Fatal("expected one vault load")
	}
	for len(events) > 0 {
		if e := <-events; e.Type == "unlock" {
			t.Fatal("duplicate unlock prompt")
		}
	}
}

func TestUnlockTimeoutCancelAndLateLoadFailClosed(t *testing.T) {
	for _, timeout := range []bool{false, true} {
		ctx, cancel := context.WithCancel(context.Background())
		events := make(chan ControlEvent, 16)
		started := make(chan struct{})
		release := make(chan struct{})
		finished := make(chan struct{})
		loaded := loadedTestAgent(t)
		target := NewAgent()
		g := NewUnlockGate(ctx, target, func(e ControlEvent) error { events <- e; return nil }, func(context.Context, string) (*Agent, error) {
			close(started)
			<-release
			defer close(finished)
			return loaded, nil
		})
		if timeout {
			g.timeout = 40 * time.Millisecond
		}
		done := make(chan bool, 1)
		go func() { done <- g.Wait(testPeer()) }()
		req := nextRequest(t, events)
		g.Unlock("test", req.ID)
		<-started
		if !timeout {
			g.Cancel(req.ID)
		}
		select {
		case ok := <-done:
			if ok {
				t.Fatal("cancel/timeout allowed request")
			}
		case <-time.After(time.Second):
			t.Fatal("cancel hung")
		}
		close(release)
		<-finished
		g.Unlock("test", req.ID)
		// Synchronize with completion under the same gate lock.
		g.mu.Lock()
		ready := g.ready
		g.mu.Unlock()
		if ready || len(target.Keys()) != 0 {
			t.Fatal("late load restored access")
		}
		if g.Wait(testPeer()) {
			t.Fatal("cooldown allowed access")
		}
		cancel()
	}
}

func TestFailedQuickSessionCanRetryBeforeRequestExpires(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	events := make(chan ControlEvent, 16)
	target := NewAgent()
	loaded := loadedTestAgent(t)
	var calls atomic.Int32
	g := NewUnlockGate(ctx, target, func(e ControlEvent) error { events <- e; return nil }, func(context.Context, string) (*Agent, error) {
		if calls.Add(1) == 1 {
			return nil, errors.New("expired session")
		}
		return loaded, nil
	})
	done := make(chan bool, 1)
	go func() { done <- g.Wait(testPeer()) }()
	req := nextRequest(t, events)
	g.Unlock("expired", req.ID)
	for {
		e := <-events
		if e.Status != nil && e.Status.State == "locked" {
			break
		}
	}
	g.Unlock("fresh", req.ID)
	select {
	case ok := <-done:
		if !ok {
			t.Fatal("retry failed")
		}
	case <-time.After(time.Second):
		t.Fatal("retry hung")
	}
}

func TestParentDisconnectClosesLockedWaiters(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	events := make(chan ControlEvent, 16)
	g := NewUnlockGate(ctx, NewAgent(), func(e ControlEvent) error { events <- e; return nil }, nil)
	var done sync.WaitGroup
	done.Add(1)
	go func() {
		defer done.Done()
		if g.Wait(testPeer()) {
			t.Error("parent EOF unlocked")
		}
	}()
	nextRequest(t, events)
	cancel()
	done.Wait()
}
