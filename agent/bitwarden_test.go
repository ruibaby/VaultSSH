package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"encoding/pem"
	"golang.org/x/crypto/ssh"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPartialLoadReportsInvalidKeys(t *testing.T) {
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	block, _ := ssh.MarshalPrivateKey(key, "")
	private := string(pem.EncodeToMemory(block))
	items := []map[string]any{{"id": "good", "name": "good", "type": 5, "sshKey": map[string]string{"privateKey": private}}, {"id": "bad", "name": "bad", "type": 5, "sshKey": map[string]string{"privateKey": "INVALID"}}}
	b, _ := json.Marshal(items)
	dir := t.TempDir()
	dataPath := filepath.Join(dir, "items.json")
	os.WriteFile(dataPath, b, 0600)
	cli := filepath.Join(dir, "bw")
	os.WriteFile(cli, []byte("#!/bin/sh\nif [ \"$2\" = sync ]; then exit 0; fi\ncat '"+dataPath+"'\n"), 0700)
	a := NewAgent()
	err := a.LoadFromBitwarden(context.Background(), cli, "dummy")
	if err != nil || len(a.Keys()) != 1 {
		t.Fatalf("unexpected %v %d", err, len(a.Keys()))
	}
	if len(a.Warnings()) != 1 || !strings.Contains(a.Warnings()[0], "bad") {
		t.Fatalf("missing key warning: %v", a.Warnings())
	}
}
