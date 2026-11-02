package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
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

func (a *Agent) LoadFromBitwarden(ctx context.Context, bwPath, session string) error {
	ctx, cancel := context.WithTimeout(ctx, 150*time.Second)
	defer cancel()

	// Sync is best effort: an existing local cache still works offline.
	syncCtx, cancelSync := context.WithTimeout(ctx, 20*time.Second)
	_, syncErr := runBW(syncCtx, bwPath, session, "sync")
	cancelSync()

	keys, problems, err := listSSHKeys(ctx, bwPath, session)
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
func listSSHKeys(ctx context.Context, bwPath, session string) ([]*Key, []string, error) {
	cmd := exec.CommandContext(ctx, bwPath, "--nointeraction", "list", "items", "--raw")
	cmd.Env = append(os.Environ(), "BW_SESSION="+session)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

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
		key, problem := keyFromItem(ctx, bwPath, session, item)
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
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = err.Error()
		}
		return nil, nil, fmt.Errorf(localized("bw list failed: %s"), message)
	}
	return keys, problems, nil
}

func keyFromItem(ctx context.Context, bwPath, session string, item BWItem) (*Key, string) {
	sshKey := item.SSHKey
	if sshKey == nil || strings.TrimSpace(sshKey.PrivateKey) == "" {
		// Some CLI versions omit secret fields from list output.
		detail, err := runBW(ctx, bwPath, session, "get", "item", item.ID, "--raw")
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

func runBW(ctx context.Context, bwPath, session string, args ...string) ([]byte, error) {
	allArgs := append([]string{"--nointeraction"}, args...)
	cmd := exec.CommandContext(ctx, bwPath, allArgs...)
	cmd.Env = append(os.Environ(), "BW_SESSION="+session)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = err.Error()
		}
		return nil, fmt.Errorf(localized("bw %s failed: %s"), args[0], message)
	}
	return out, nil
}
