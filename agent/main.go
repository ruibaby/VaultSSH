package main

import (
	"context"
	"flag"
	"fmt"
	"golang.org/x/sys/unix"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func main() {
	socketPath := flag.String("socket", "", "unix socket path")
	statusPath := flag.String("status", "", "status json path")
	eventsPath := flag.String("events", "", "events jsonl path")
	bwPath := flag.String("bw", "", "npm Bitwarden CLI entry path")
	nodePath := flag.String("node", "", "Node.js executable path")
	bridgePath := flag.String("bridge", "", "bundled CLI bridge path")

	mockKey := flag.String("mock-key", "", "development: load a local private key instead of Bitwarden")
	flag.Parse()

	if *socketPath == "" || *statusPath == "" || *eventsPath == "" {
		log.Fatal("--socket, --status and --events are required")
	}
	for _, p := range []string{*socketPath, *statusPath, *eventsPath} {
		dir := filepath.Dir(p)
		if err := os.MkdirAll(dir, 0700); err != nil {
			log.Fatal(err)
		}
		_ = os.Chmod(dir, 0700)
	}

	ctx, stopSignals := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stopSignals()
	control := NewControlChannel(os.Stdin, os.Stdout, stopSignals)
	defer control.Close()
	defer control.Flush()
	// Keep ownership until exit; never unlink another helper's live socket.
	lock, err := os.OpenFile(*socketPath+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		log.Fatal(err)
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = control.Send(ControlEvent{Type: "status", Status: &Status{State: "error", Error: localized("Another agent is running. Quit the previous VaultSSH instance first.")}})
		return
	}
	events := NewEventLogger(*eventsPath)
	events.notify = func(e Event) { _ = control.Send(ControlEvent{Type: "event", Event: &e}) }
	defer events.Close()
	status := NewStatusWriter(*statusPath)
	status.notify = func(s Status) { _ = control.Send(ControlEvent{Type: "status", Status: &s}) }
	baseStatus := func(state, errMsg string, keys []KeyInfo) Status {
		return Status{State: state, PID: os.Getpid(), Socket: *socketPath, Keys: keys, Error: errMsg}
	}
	status.Write(baseStatus("starting", "", nil))

	if conn, err := net.DialTimeout("unix", *socketPath, 300*time.Millisecond); err == nil {
		conn.Close()
		status.Write(baseStatus("error", localized("Another agent is already running."), nil))
		return
	}
	_ = os.Remove(*socketPath)

	ln, err := net.Listen("unix", *socketPath)
	if err != nil {
		status.Write(baseStatus("error", err.Error(), nil))
		return
	}
	_ = os.Chmod(*socketPath, 0600)
	pidPath := filepath.Join(filepath.Dir(*socketPath), "agent.pid")
	_ = os.WriteFile(pidPath, []byte(strconv.Itoa(os.Getpid())), 0600)

	cleanup := func(state string) {
		_ = ln.Close()
		_ = os.Remove(*socketPath)
		_ = os.Remove(pidPath)
		status.Write(baseStatus(state, "", nil))
	}

	a := NewAgent()
	approver := NewApprover(60*time.Second, control.Send)
	defer approver.Close()
	session, keyOrder, err := control.ReadSession()
	if err != nil {
		cleanup("stopped")
		return
	}
	a.SetKeyOrder(keyOrder)
	go control.ReadCommands(approver, a)
	go func() { <-ctx.Done(); _ = ln.Close() }()
	status.Write(baseStatus("loading", "", nil))

	var loadErr error
	if *mockKey != "" {
		loadErr = a.LoadFile(*mockKey)
	} else {
		if strings.TrimSpace(session) == "" {
			loadErr = fmt.Errorf("%s", localized("No Bitwarden session. Unlock in the app."))
		} else {
			loadErr = a.LoadFromBitwarden(ctx, VaultCLI{Node: *nodePath, Bridge: *bridgePath, Path: *bwPath}, session)
		}
	}
	if loadErr != nil {
		events.Event(Event{Type: "error", Result: "error", Detail: loadErr.Error()})
		status.Write(Status{State: "error", PID: os.Getpid(), Socket: *socketPath, Error: loadErr.Error()})
		_ = ln.Close()
		_ = os.Remove(*socketPath)
		_ = os.Remove(pidPath)
		return
	}

	keys := a.KeyInfos()
	ready := baseStatus("ready", "", keys)
	ready.Warnings = a.Warnings()
	status.Write(ready)
	for _, warning := range ready.Warnings {
		events.Event(Event{Type: "warning", Result: "warning", Detail: warning})
	}
	events.Event(Event{Type: "ready", Result: "ok", Detail: fmt.Sprintf(localized("Keys: %d"), len(keys))})

	serveErr := serveAgent(ctx, ln, a, events, approver)
	cleanup("stopped")
	if serveErr != nil {
		status.Write(baseStatus("error", localized("The SSH socket stopped unexpectedly."), nil))
	}
}
