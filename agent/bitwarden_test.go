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
	"time"
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
	cli := testVaultCLI(t, dir, `if (!process.env.BW_SESSION) process.exit(1);
if (process.argv.includes('list')) process.stdout.write(require('node:fs').readFileSync(require('node:path').join(__dirname, '../items.json')));`)
	a := NewAgent()
	err := a.LoadFromBitwarden(context.Background(), cli, "dummy", false, nil)
	if err != nil || len(a.Keys()) != 1 {
		t.Fatalf("unexpected %v %d", err, len(a.Keys()))
	}
	if len(a.Warnings()) != 1 || !strings.Contains(a.Warnings()[0], "bad") {
		t.Fatalf("missing key warning: %v", a.Warnings())
	}
}

func testVaultCLI(t *testing.T, dir, script string) VaultCLI {
	t.Helper()
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
	os.WriteFile(entry, []byte(script), 0600)
	bridge, _ := filepath.Abs("../Sources/VaultSSH/Resources/CLI/bridge.cjs")
	return VaultCLI{Node: node, Bridge: bridge, Path: entry}
}

func TestCachedUnlockDoesNotWaitForSync(t *testing.T) {
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	block, _ := ssh.MarshalPrivateKey(key, "")
	items, _ := json.Marshal([]map[string]any{{"id": "cached", "type": 5, "sshKey": map[string]string{"privateKey": string(pem.EncodeToMemory(block))}}})
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "items.json"), items, 0600)
	cli := testVaultCLI(t, dir, `const fs = require('node:fs'), path = require('node:path');
const op = process.argv.includes('sync') ? 'sync' : 'list';
fs.appendFileSync(path.join(__dirname, '../operations'), op + '\n');
if (op === 'sync') setTimeout(() => {}, 3000);
else process.stdout.write(fs.readFileSync(path.join(__dirname, '../items.json')));`)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	a := NewAgent()
	started := time.Now()
	err := a.LoadFromBitwarden(ctx, cli, "disposable", false, nil)
	operations, _ := os.ReadFile(filepath.Join(dir, "operations"))
	if err != nil || len(a.Keys()) != 1 || string(operations) != "list\n" {
		t.Fatalf("cached unlock waited for sync: operations=%q elapsed=%s keys=%d error=%v", operations, time.Since(started), len(a.Keys()), err)
	}
}

func TestVaultSyncPolicyAndProgress(t *testing.T) {
	for _, tc := range []struct {
		name                                string
		empty, invalid, syncVault, failSync bool
		operations, phases                  string
	}{
		{name: "cached", operations: "list\n", phases: "loadingKeys"},
		{name: "empty cache bootstraps", empty: true, operations: "list\nsync\nlist\n", phases: "loadingKeys,syncing,loadingKeys"},
		{name: "invalid cached key recovers", invalid: true, operations: "list\nsync\nlist\n", phases: "loadingKeys,syncing,loadingKeys"},
		{name: "manual refresh", syncVault: true, operations: "sync\nlist\n", phases: "syncing,loadingKeys"},
		{name: "offline refresh keeps cached keys", syncVault: true, failSync: true, operations: "sync\nlist\n", phases: "syncing,loadingKeys"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, key, _ := ed25519.GenerateKey(rand.Reader)
			block, _ := ssh.MarshalPrivateKey(key, "")
			items, _ := json.Marshal([]map[string]any{{"id": "cached", "type": 5, "sshKey": map[string]string{"privateKey": string(pem.EncodeToMemory(block))}}})
			dir := t.TempDir()
			os.WriteFile(filepath.Join(dir, "remote.json"), items, 0600)
			if tc.empty {
				os.WriteFile(filepath.Join(dir, "items.json"), []byte("[]"), 0600)
			} else if tc.invalid {
				os.WriteFile(filepath.Join(dir, "items.json"), []byte(`[{"id":"broken","type":5,"sshKey":{"privateKey":"INVALID"}}]`), 0600)
			} else {
				os.WriteFile(filepath.Join(dir, "items.json"), items, 0600)
			}
			if tc.failSync {
				os.WriteFile(filepath.Join(dir, "offline"), nil, 0600)
			}
			cli := testVaultCLI(t, dir, `const fs = require('node:fs'), path = require('node:path');
const file = name => path.join(__dirname, '..', name);
const op = process.argv.includes('sync') ? 'sync' : 'list';
fs.appendFileSync(file('operations'), op + '\n');
if (op === 'sync') {
 if (fs.existsSync(file('offline'))) process.exit(1);
 fs.copyFileSync(file('remote.json'), file('items.json'));
} else process.stdout.write(fs.readFileSync(file('items.json')));`)
			a := NewAgent()
			var phases []string
			err := a.LoadFromBitwarden(context.Background(), cli, "disposable", tc.syncVault, func(phase string) { phases = append(phases, phase) })
			operations, _ := os.ReadFile(filepath.Join(dir, "operations"))
			if err != nil || len(a.Keys()) != 1 || string(operations) != tc.operations || strings.Join(phases, ",") != tc.phases {
				t.Fatalf("operations=%q phases=%v keys=%d error=%v", operations, phases, len(a.Keys()), err)
			}
			if (len(a.Warnings()) > 0) != tc.failSync {
				t.Fatalf("unexpected warnings: %v", a.Warnings())
			}
		})
	}
}
