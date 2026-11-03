package main

import (
	"context"
	"io"
	"net"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestCredentialsUseOnlyStdin(t *testing.T) {
	t.Setenv("BW_SESSION", "inherited-secret")
	t.Setenv("NODE_OPTIONS", "--require=/untrusted.js")
	cli := VaultCLI{Node: "/node", Bridge: "/bridge", Path: "/bw"}
	cmd, err := cli.command(context.Background(), "test-session", "list")
	if err != nil {
		t.Fatal(err)
	}
	startup := strings.Join(append(cmd.Args, cmd.Env...), " ")
	for _, forbidden := range []string{"inherited-secret", "test-session", "NODE_OPTIONS", "BW_SESSION"} {
		if strings.Contains(startup, forbidden) {
			t.Fatalf("startup contains %s", forbidden)
		}
	}
	input, _ := io.ReadAll(cmd.Stdin)
	if string(input) != `{"session":"test-session"}` {
		t.Fatal("missing stdin credential")
	}
}

func TestInterpreterGrantsAreNeverCached(t *testing.T) {
	for _, path := range []string{"", "/usr/bin/python3.12", "/opt/node", "/bin/zsh", "/usr/bin/osascript"} {
		for _, parent := range []bool{false, true} {
			peer := testPeer()
			if parent {
				peer.ParentExecutable = path
			} else {
				peer.Executable = path
			}
			a, events := testApprover(time.Second)
			for i := 0; i < 2; i++ {
				done := approveAsync(a, peer)
				req := nextRequest(t, events)
				if req.CacheAllowed {
					t.Fatalf("cache offered for %s", path)
				}
				a.Decide(approvalDecision{ID: req.ID, Allow: true, GraceSeconds: 300})
				if !<-done {
					t.Fatal("explicit approval denied")
				}
			}
			a.Close()
		}
	}
}

func TestPartialFrameTimesOutButIdleConnectionSurvives(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	done := make(chan error, 1)
	go func() { _, err := readConnMessage(server, 40*time.Millisecond); done <- err }()
	select {
	case err := <-done:
		t.Fatalf("idle connection ended: %v", err)
	case <-time.After(80 * time.Millisecond):
	}
	if _, err := client.Write([]byte{0}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if e, ok := err.(net.Error); !ok || !e.Timeout() {
			t.Fatalf("wanted timeout: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("partial frame retained connection")
	}
}

func TestActivityFloodPreservesApprovalCapacity(t *testing.T) {
	// No consumer: reproduce a blocked parent deterministically.
	c := &ControlChannel{output: make(chan ControlEvent, 256), done: make(chan struct{}), cancel: func() {}}
	for i := 0; i < 10000; i++ {
		if err := c.Send(ControlEvent{Type: "event"}); err != nil {
			t.Fatal(err)
		}
	}
	if err := c.Send(ControlEvent{Type: "approval"}); err != nil {
		t.Fatal(err)
	}
	if len(c.output) != 65 {
		t.Fatalf("unexpected queue length %d", len(c.output))
	}
	c.Close()
	if c.Send(ControlEvent{Type: "event"}) == nil {
		t.Fatal("closed channel accepted event")
	}
}

// Exercise resource-error recovery without changing the test runner's limits.
type exhaustedListener struct {
	attempts int
}

func (l *exhaustedListener) Accept() (net.Conn, error) {
	l.attempts++
	switch l.attempts {
	case 1:
		return nil, &net.OpError{Op: "accept", Net: "unix", Err: syscall.EMFILE}
	case 2:
		return nil, &net.OpError{Op: "accept", Net: "unix", Err: syscall.ENFILE}
	default:
		return nil, net.ErrClosed
	}
}
func (*exhaustedListener) Close() error   { return nil }
func (*exhaustedListener) Addr() net.Addr { return &net.UnixAddr{Name: "test", Net: "unix"} }

func TestResourceErrorsRetryAndShutdownRevokesPending(t *testing.T) {
	listener := &exhaustedListener{}
	approver, events := testApprover(time.Minute)
	pending := approveAsync(approver, testPeer())
	nextRequest(t, events)
	start := time.Now()
	if err := serveAgent(context.Background(), listener, NewAgent(), nil, approver); err != nil {
		t.Fatal(err)
	}
	if listener.attempts != 3 {
		t.Fatal("accept did not retry resource exhaustion")
	}
	if time.Since(start) < 180*time.Millisecond {
		t.Fatal("resource-error retry loop did not back off")
	}
	select {
	case allowed := <-pending:
		if allowed {
			t.Fatal("shutdown allowed pending request")
		}
	case <-time.After(time.Second):
		t.Fatal("shutdown retained pending approval")
	}
}

func TestEmptyCLIEnvironmentDoesNotInheritParent(t *testing.T) {
	for _, name := range []string{"HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "BITWARDENCLI_APPDATA_DIR",
		"HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE"} {
		t.Setenv(name, "") // Register restoration before removing the variable.
		os.Unsetenv(name)
	}
	t.Setenv("BW_SESSION", "parent-only-secret")
	cmd, err := (VaultCLI{Node: "/node", Bridge: "/bridge", Path: "/bw"}).command(context.Background(), "test", "list")
	if err != nil {
		t.Fatal(err)
	}
	if cmd.Env == nil || len(cmd.Environ()) != 0 {
		t.Fatal("empty allowlist inherited parent environment")
	}
}
