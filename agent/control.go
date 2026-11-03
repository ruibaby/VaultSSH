package main

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"sync"
	"time"
)

type ControlEvent struct {
	flushed chan struct{}
	Type    string           `json:"type"`
	ID      string           `json:"id,omitempty"`
	Request *ApprovalRequest `json:"request,omitempty"`
	Status  *Status          `json:"status,omitempty"`
	Event   *Event           `json:"event,omitempty"`
	Keys    []KeyInfo        `json:"keys,omitempty"`
}

type ControlCommand struct {
	Type     string            `json:"type"`
	Session  string            `json:"session,omitempty"`
	Decision *approvalDecision `json:"decision,omitempty"`
	KeyOrder []string          `json:"keyOrder,omitempty"`
}

// stdin/stdout are anonymous pipes inherited from the launching app. There is
// no named authorization endpoint another same-user process can open.
type ControlChannel struct {
	scanner *bufio.Scanner
	output  chan ControlEvent
	done    chan struct{}
	once    sync.Once
	cancel  context.CancelFunc
}

func NewControlChannel(r io.Reader, w io.Writer, cancel context.CancelFunc) *ControlChannel {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	c := &ControlChannel{scanner: scanner, output: make(chan ControlEvent, 256), done: make(chan struct{}), cancel: cancel}
	go func() {
		enc := json.NewEncoder(w)
		for {
			select {
			case <-c.done:
				return
			case event := <-c.output:
				if event.flushed != nil {
					close(event.flushed)
					continue
				}
				if enc.Encode(event) != nil {
					c.Close()
					return
				}
			}
		}
	}()
	return c
}

func (c *ControlChannel) Send(event ControlEvent) error {
	select {
	case <-c.done:
		return errControlClosed
	default:
	}
	// Reserve capacity for approval/status messages. A client flooding activity
	// must not shut down the control channel or displace authorization traffic.
	if event.Type == "event" && len(c.output) >= 64 {
		return nil
	}
	select {
	case <-c.done:
		return errControlClosed
	case c.output <- event:
		return nil
	default:
		c.Close()
		return errControlClosed
	}
}

func (c *ControlChannel) ReadSession() (string, []string, error) {
	if !c.scanner.Scan() {
		return "", nil, errControlClosed
	}
	var command ControlCommand
	if json.Unmarshal(c.scanner.Bytes(), &command) != nil || command.Type != "session" {
		return "", nil, errControlClosed
	}
	return command.Session, command.KeyOrder, nil
}

func (c *ControlChannel) ReadCommands(a *Approver, keys *Agent) {
	defer c.Close()
	defer a.Close()
	for c.scanner.Scan() {
		var command ControlCommand
		if json.Unmarshal(c.scanner.Bytes(), &command) != nil {
			return
		}
		switch command.Type {
		case "keyOrder":
			keys.SetKeyOrder(command.KeyOrder)
			_ = c.Send(ControlEvent{Type: "keys", Keys: keys.KeyInfos()})
		case "decision":
			if command.Decision != nil {
				a.Decide(*command.Decision)
			}
		case "revoke":
			a.Revoke()
			_ = c.Send(ControlEvent{Type: "revoked"})
		default:
			return
		}
	}
}

func (c *ControlChannel) Close() { c.once.Do(func() { close(c.done); c.cancel() }) }

func (c *ControlChannel) Flush() {
	done := make(chan struct{})
	if c.Send(ControlEvent{flushed: done}) != nil {
		return
	}
	select {
	case <-done:
	case <-time.After(250 * time.Millisecond):
	}
}
