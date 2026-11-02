package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"net"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
)

func startTestServer(t *testing.T, a *Agent) agent.ExtendedAgent {
	t.Helper()
	dir := t.TempDir()
	socketPath := filepath.Join(dir, "agent.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	events := NewEventLogger(filepath.Join(dir, "events.jsonl"))
	var approver *Approver
	approver = NewApprover(time.Second, func(e ControlEvent) error {
		if e.Request != nil {
			approver.Decide(approvalDecision{ID: e.Request.ID, Allow: true})
		}
		return nil
	})
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go handleConn(conn, a, events, approver)
		}
	}()

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return agent.NewClient(conn)
}

func testKey(id, name string, signer ssh.Signer) *Key {
	return &Key{
		ID:          id,
		Name:        name,
		Signer:      signer,
		PublicKey:   signer.PublicKey(),
		Fingerprint: sshFingerprint(signer.PublicKey()),
	}
}

func TestAgentListAndSign(t *testing.T) {
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		t.Fatal(err)
	}
	a := NewAgent()
	a.SetKeys([]*Key{testKey("test", "test-key", signer)})

	client := startTestServer(t, a)
	keys, err := client.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 1 {
		t.Fatalf("got %d keys, want 1", len(keys))
	}
	if keys[0].Comment != "test-key" {
		t.Fatalf("comment = %q, want test-key", keys[0].Comment)
	}

	data := []byte("hello vaultssh")
	signature, err := client.Sign(keys[0], data)
	if err != nil {
		t.Fatal(err)
	}
	if err := signer.PublicKey().Verify(data, signature); err != nil {
		t.Fatalf("signature verification failed: %v", err)
	}
}

func TestAgentRsaSha2Flags(t *testing.T) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		t.Fatal(err)
	}
	a := NewAgent()
	a.SetKeys([]*Key{testKey("rsa", "rsa-key", signer)})

	client := startTestServer(t, a)
	keys, err := client.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 1 {
		t.Fatalf("got %d keys, want 1", len(keys))
	}

	data := []byte("rsa signing test")
	signature, err := client.SignWithFlags(keys[0], data, agent.SignatureFlagRsaSha256)
	if err != nil {
		t.Fatal(err)
	}
	if signature.Format != ssh.KeyAlgoRSASHA256 {
		t.Fatalf("signature format = %q, want %q", signature.Format, ssh.KeyAlgoRSASHA256)
	}
	if err := signer.PublicKey().Verify(data, signature); err != nil {
		t.Fatalf("signature verification failed: %v", err)
	}
}
