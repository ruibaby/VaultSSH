package main

import (
	"context"
	"errors"
	"net"
	"sync"
	"syscall"
	"time"
)

const maxAgentConnections = 32

func serveAgent(ctx context.Context, listener net.Listener, a *Agent, events *EventLogger, approver *Approver) error {
	finished := make(chan struct{})
	defer close(finished)
	go func() {
		select {
		case <-ctx.Done():
			_ = listener.Close()
		case <-finished:
		}
	}()
	var mu sync.Mutex
	active := make(map[net.Conn]struct{})
	var handlers sync.WaitGroup
	defer func() {
		approver.Close()
		if a.unlock != nil {
			a.unlock.Close()
		}
		mu.Lock()
		for conn := range active {
			_ = conn.Close()
		}
		mu.Unlock()
		handlers.Wait()
	}()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			if errors.Is(err, syscall.EMFILE) || errors.Is(err, syscall.ENFILE) {
				select {
				case <-ctx.Done():
					return nil
				case <-time.After(100 * time.Millisecond):
					continue
				}
			}
			return err
		}
		mu.Lock()
		if len(active) >= maxAgentConnections {
			mu.Unlock()
			_ = conn.Close()
			continue
		}
		active[conn] = struct{}{}
		mu.Unlock()
		handlers.Add(1)
		go func() {
			defer handlers.Done()
			defer func() { mu.Lock(); delete(active, conn); mu.Unlock() }()
			handleConn(conn, a, events, approver)
		}()
	}
}
