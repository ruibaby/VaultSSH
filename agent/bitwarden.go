package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

const cipherTypeSSHKey = 5

type BWItem struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Type   int    `json:"type"`
	SSHKey *struct {
		PrivateKey     string `json:"privateKey"`
		PublicKey      string `json:"publicKey"`
		KeyFingerprint string `json:"keyFingerprint"`
	} `json:"sshKey"`
}

func (a *Agent) LoadFromBitwarden(ctx context.Context, cli VaultCLI, session string) error {
	ctx, cancel := context.WithTimeout(ctx, 150*time.Second)
	defer cancel()

	// Sync is best effort: an existing local cache still works offline.
	syncCtx, cancelSync := context.WithTimeout(ctx, 20*time.Second)
	_, syncErr := runBW(syncCtx, cli, session, "sync")
	cancelSync()

	keys, problems, err := listSSHKeys(ctx, cli, session)
	if err != nil {
		return err
	}
	if len(keys) == 0 {
		if len(problems) > 0 {
			return fmt.Errorf(localized("No usable SSH keys: %s"), strings.Join(problems, "; "))
		}
		return errors.New(localized("No SSH key items found in the vault."))
	}
	if syncErr != nil {
		problems = append(problems, localized("Sync failed; using the local cache: ")+syncErr.Error())
	}
	a.mu.Lock()
	a.keys = keys
	a.warnings = problems
	a.mu.Unlock()
	return nil
}

// listSSHKeys streams the vault list instead of buffering the entire JSON
// document, so non-SSH secrets are not held in this process memory.
func listSSHKeys(ctx context.Context, cli VaultCLI, session string) ([]*Key, []string, error) {
	cmd, err := cli.command(ctx, session, "list")
	if err != nil {
		return nil, nil, err
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, nil, err
	}

	decoder := json.NewDecoder(stdout)
	token, err := decoder.Token()
	if err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return nil, nil, fmt.Errorf(localized("bw list did not return a JSON array: %w"), err)
	}
	delim, ok := token.(json.Delim)
	if !ok || delim != '[' {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return nil, nil, errors.New(localized("bw list did not return a JSON array."))
	}

	var keys []*Key
	var problems []string
	for decoder.More() {
		var item BWItem
		if err := decoder.Decode(&item); err != nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
			return nil, nil, fmt.Errorf(localized("Could not parse bw output: %w"), err)
		}
		if item.Type != cipherTypeSSHKey {
			continue
		}
		key, problem := keyFromItem(ctx, cli, session, item)
		if problem != "" {
			problems = append(problems, problem)
			continue
		}
		keys = append(keys, key)
	}
	if _, err := decoder.Token(); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return nil, nil, fmt.Errorf(localized("Could not parse bw output: %w"), err)
	}

	if err := cmd.Wait(); err != nil {
		return nil, nil, fmt.Errorf("%s", localized("Secure CLI command failed. Check your login, server and network."))
	}
	return keys, problems, nil
}

func keyFromItem(ctx context.Context, cli VaultCLI, session string, item BWItem) (*Key, string) {
	sshKey := item.SSHKey
	if sshKey == nil || strings.TrimSpace(sshKey.PrivateKey) == "" {
		// Some CLI versions omit secret fields from list output.
		detail, err := runBW(ctx, cli, session, "get", item.ID)
		if err != nil {
			return nil, fmt.Sprintf("%s: %v", item.Name, err)
		}
		var single BWItem
		if err := json.Unmarshal(detail, &single); err != nil {
			return nil, fmt.Sprintf("%s: %v", item.Name, err)
		}
		sshKey = single.SSHKey
	}
	if sshKey == nil || strings.TrimSpace(sshKey.PrivateKey) == "" {
		return nil, fmt.Sprintf(localized("%s: missing private key"), item.Name)
	}
	signer, err := parseSigner(sshKey.PrivateKey)
	if err != nil {
		return nil, fmt.Sprintf("%s: %v", item.Name, err)
	}
	pub := signer.PublicKey()
	return &Key{
		ID:          item.ID,
		Name:        item.Name,
		Signer:      signer,
		PublicKey:   pub,
		Fingerprint: sshFingerprint(pub),
	}, ""
}
