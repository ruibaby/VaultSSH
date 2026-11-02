//go:build darwin

package main

import (
	"os/exec"
	"path/filepath"
	"testing"
)

func TestExecutableIdentityIgnoresArgvZero(t *testing.T) {
	cmd := exec.Command("/bin/sleep", "5")
	cmd.Args[0] = "/usr/bin/ssh"
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	peer := lookupPeer(cmd.Process.Pid)
	if filepath.Base(peer.Executable) != "sleep" {
		t.Fatalf("untrusted executable identity: %q", peer.Executable)
	}
	if peer.ParentExecutable == "" {
		t.Fatal("missing parent identity")
	}
}
