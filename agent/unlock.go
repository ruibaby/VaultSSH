package main

import (
	"context"
	"sync"
	"time"
)

// A locked helper owns only the socket. Keys are loaded after an explicit
// decision over the app's inherited pipe; socket clients cannot unlock it.
type UnlockGate struct {
	mu         sync.Mutex
	ctx        context.Context
	agent      *Agent
	emit       func(ControlEvent) error
	load       func(context.Context, string, func(string)) (*Agent, error)
	timeout    time.Duration
	closed     bool
	ready      bool
	loading    bool
	generation uint64
	cancel     context.CancelFunc
	batch      *unlockBatch
	cooldown   time.Time
}

type unlockBatch struct {
	id      string
	expires time.Time
	done    chan struct{}
	allowed bool
}

func NewUnlockGate(ctx context.Context, a *Agent, emit func(ControlEvent) error,
	load func(context.Context, string, func(string)) (*Agent, error)) *UnlockGate {
	return &UnlockGate{ctx: ctx, agent: a, emit: emit, load: load, timeout: 120 * time.Second}
}

func (g *UnlockGate) Wait(peer PeerInfo) bool {
	g.mu.Lock()
	if g.closed {
		g.mu.Unlock()
		return false
	}
	if g.ready {
		g.mu.Unlock()
		return true
	}
	if g.ctx.Err() != nil || time.Now().Before(g.cooldown) {
		g.mu.Unlock()
		return false
	}
	if g.batch == nil {
		id, err := randomID()
		if err != nil {
			g.mu.Unlock()
			return false
		}
		batch := &unlockBatch{id: id, expires: time.Now().Add(g.timeout), done: make(chan struct{})}
		g.batch = batch
		request := &ApprovalRequest{ID: id, Created: time.Now().Format(time.RFC3339Nano), ExpiresAt: batch.expires.Format(time.RFC3339Nano),
			PID: peer.PID, Process: peer.Process, Executable: peer.Executable, ParentPID: peer.ParentPID,
			ParentProcess: peer.ParentProcess, ParentExecutable: peer.ParentExecutable}
		if g.emit(ControlEvent{Type: "unlock", Request: request}) != nil {
			g.finishLocked(false)
			g.mu.Unlock()
			return false
		}
		go func() {
			timer := time.NewTimer(time.Until(batch.expires))
			defer timer.Stop()
			select {
			case <-timer.C:
				g.Cancel(batch.id)
			case <-g.ctx.Done():
				g.Cancel(batch.id)
			case <-batch.done:
			}
		}()
	}
	batch := g.batch
	g.mu.Unlock()
	select {
	case <-batch.done:
		return batch.allowed
	case <-g.ctx.Done():
		return false
	}
}

// A batch ID binds an SSH-triggered unlock to its still-live request. Empty IDs
// are reserved for explicit unlock from the main window or menu bar.
func (g *UnlockGate) Unlock(session, id string) {
	g.mu.Lock()
	if g.closed || g.ready || g.loading || g.ctx.Err() != nil ||
		(id != "" && (g.batch == nil || g.batch.id != id || !time.Now().Before(g.batch.expires))) {
		g.mu.Unlock()
		return
	}
	g.loading = true
	generation := g.generation
	ctx, cancel := context.WithTimeout(g.ctx, 150*time.Second)
	g.cancel = cancel
	_ = g.emit(ControlEvent{Type: "status", Status: &Status{State: "loading"}})
	g.mu.Unlock()
	go func() {
		defer cancel()
		loaded, err := g.load(ctx, session, func(phase string) {
			g.mu.Lock()
			defer g.mu.Unlock()
			if !g.closed && generation == g.generation && ctx.Err() == nil && g.loading {
				_ = g.emit(ControlEvent{Type: "status", Status: &Status{State: "loading", Phase: phase}})
			}
		})
		g.mu.Lock()
		defer g.mu.Unlock()
		if g.closed || generation != g.generation || g.ctx.Err() != nil {
			return
		}
		g.loading = false
		g.cancel = nil
		if ctx.Err() != nil {
			err = ctx.Err()
		}
		if err != nil {
			_ = g.emit(ControlEvent{Type: "status", Status: &Status{State: "locked", Error: err.Error()}})
			// Keep the batch pending so the user can retry with the master password.
			return
		}
		g.agent.SetKeys(loaded.Keys())
		g.ready = true
		_ = g.emit(ControlEvent{Type: "status", Status: &Status{State: "ready", Keys: g.agent.KeyInfos(), Warnings: loaded.Warnings()}})
		g.finishLocked(true)
	}()
}

func (g *UnlockGate) Cancel(id string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.batch == nil || g.batch.id != id {
		return
	}
	g.generation++
	if g.cancel != nil {
		g.cancel()
		g.cancel = nil
	}
	g.loading = false
	g.cooldown = time.Now().Add(10 * time.Second)
	g.finishLocked(false)
	_ = g.emit(ControlEvent{Type: "status", Status: &Status{State: "locked"}})
}

func (g *UnlockGate) finishLocked(allow bool) {
	if batch := g.batch; batch != nil {
		batch.allowed = allow
		close(batch.done)
		_ = g.emit(ControlEvent{Type: "unlockDismiss", ID: batch.id})
		g.batch = nil
	}
}

func (g *UnlockGate) Close() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.closed = true
	g.generation++
	if g.cancel != nil {
		g.cancel()
		g.cancel = nil
	}
	g.finishLocked(false)
}
