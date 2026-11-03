package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
)

// VaultCLI owns the only credential-bearing path into the npm CLI. The Node
// bridge receives credentials after exec, never in startup args/environment.
type VaultCLI struct {
	Node   string
	Bridge string
	Path   string
}

func (cli VaultCLI) command(ctx context.Context, session, operation string, args ...string) (*exec.Cmd, error) {
	if cli.Node == "" || cli.Bridge == "" || cli.Path == "" {
		return nil, fmt.Errorf("%s", localized("Secure CLI transport is unavailable. Install the supported npm CLI."))
	}
	input, _ := json.Marshal(map[string]string{"session": session})
	if len(input) > 65536 {
		return nil, fmt.Errorf("%s", localized("Invalid CLI credential input."))
	}
	cmd := exec.CommandContext(ctx, cli.Node, append([]string{cli.Bridge, cli.Path, operation}, args...)...)
	cmd.Stdin = bytes.NewReader(input)
	cmd.Env = []string{} // A nil Env would inherit all parent variables.
	for _, name := range []string{"HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "BITWARDENCLI_APPDATA_DIR",
		"HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE"} {
		if value, ok := os.LookupEnv(name); ok {
			cmd.Env = append(cmd.Env, name+"="+value)
		}
	}
	// Do not inherit the helper's control descriptors or leak raw diagnostics.
	cmd.Stderr = nil
	return cmd, nil
}

func runBW(ctx context.Context, cli VaultCLI, session, operation string, args ...string) ([]byte, error) {
	cmd, err := cli.command(ctx, session, operation, args...)
	if err != nil {
		return nil, err
	}
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("%s", localized("Secure CLI command failed. Check your login, server and network."))
	}
	return out, nil
}
