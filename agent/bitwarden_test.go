package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"encoding/pem"
	"golang.org/x/crypto/ssh"
	"os"
	"os/exec"
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
	node, err := exec.LookPath("node")
	if err != nil {
		t.Fatal("Node.js is required for secure CLI tests")
	}
	build := filepath.Join(dir, "build")
	os.MkdirAll(build, 0700)
	manifest, err := os.ReadFile("../Sources/VaultSSH/Resources/CLI/package.json")
	if err != nil {
		t.Fatal(err)
	}
	var runtime struct{ Dependencies map[string]string }
	if err := json.Unmarshal(manifest, &runtime); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "package.json"), []byte(`{"name":"@bitwarden/cli","version":"`+runtime.Dependencies["@bitwarden/cli"]+`"}`), 0600)
	entry := filepath.Join(build, "bw.js")
	os.WriteFile(entry, []byte(`if (!process.env.BW_SESSION) process.exit(1);
if (process.argv.includes('list')) process.stdout.write(require('node:fs').readFileSync(require('node:path').join(__dirname, '../items.json')));`), 0600)
	bridge, _ := filepath.Abs("../Sources/VaultSSH/Resources/CLI/bridge.cjs")
	cli := VaultCLI{Node: node, Bridge: bridge, Path: entry}
	a := NewAgent()
	err = a.LoadFromBitwarden(context.Background(), cli, "dummy")
	if err != nil || len(a.Keys()) != 1 {
		t.Fatalf("unexpected %v %d", err, len(a.Keys()))
	}
	if len(a.Warnings()) != 1 || !strings.Contains(a.Warnings()[0], "bad") {
		t.Fatalf("missing key warning: %v", a.Warnings())
	}
}
