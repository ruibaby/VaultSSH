package main

import (
	"bytes"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
)

type Key struct {
	ID          string
	Name        string
	Signer      ssh.Signer
	PublicKey   ssh.PublicKey
	Fingerprint string
}

type Agent struct {
	mu       sync.RWMutex
	keys     []*Key
	warnings []string
	keyOrder []string
}

func NewAgent() *Agent {
	return &Agent{}
}

func (a *Agent) SetKeys(keys []*Key) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.keys = keys
}

func (a *Agent) Keys() []*Key {
	a.mu.RLock()
	defer a.mu.RUnlock()
	out := make([]*Key, len(a.keys))
	copy(out, a.keys)
	rank := make(map[string]int, len(a.keyOrder))
	for i, fingerprint := range a.keyOrder {
		if _, exists := rank[fingerprint]; !exists {
			rank[fingerprint] = i
		}
	}
	priority := func(k *Key) int {
		if value, exists := rank[k.Fingerprint]; exists {
			return value
		}
		return len(a.keyOrder)
	}
	sort.SliceStable(out, func(i, j int) bool { return priority(out[i]) < priority(out[j]) })
	return out
}

func (a *Agent) SetKeyOrder(order []string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.keyOrder = append([]string(nil), order...)
}

func (a *Agent) Find(blob []byte) *Key {
	a.mu.RLock()
	defer a.mu.RUnlock()
	for _, k := range a.keys {
		if bytes.Equal(k.PublicKey.Marshal(), blob) {
			return k
		}
	}
	return nil
}

func (a *Agent) KeyInfos() []KeyInfo {
	keys := a.Keys()
	out := make([]KeyInfo, 0, len(keys))
	for _, k := range keys {
		out = append(out, KeyInfo{
			ID:          k.ID,
			Name:        k.Name,
			Type:        k.PublicKey.Type(),
			Fingerprint: k.Fingerprint,
			PublicKey:   strings.TrimSpace(string(ssh.MarshalAuthorizedKey(k.PublicKey))),
		})
	}
	return out
}

func parseSigner(privateKey string) (ssh.Signer, error) {
	raw, err := ssh.ParseRawPrivateKey([]byte(strings.TrimSpace(privateKey)))
	if err != nil {
		var missing *ssh.PassphraseMissingError
		if errors.As(err, &missing) {
			return nil, errors.New(localized("Passphrase-protected private keys are not supported."))
		}
		return nil, fmt.Errorf(localized("Could not parse private key: %w"), err)
	}
	signer, err := ssh.NewSignerFromKey(raw)
	if err != nil {
		return nil, fmt.Errorf(localized("Could not create signer: %w"), err)
	}
	return signer, nil
}

func sshFingerprint(pub ssh.PublicKey) string {
	return ssh.FingerprintSHA256(pub)
}

func signWithFlags(s ssh.Signer, data []byte, flags uint32) (*ssh.Signature, error) {
	if s.PublicKey().Type() == ssh.KeyAlgoRSA {
		var alg string
		if flags&uint32(agent.SignatureFlagRsaSha512) != 0 {
			alg = ssh.KeyAlgoRSASHA512
		} else if flags&uint32(agent.SignatureFlagRsaSha256) != 0 {
			alg = ssh.KeyAlgoRSASHA256
		}
		if alg != "" {
			if as, ok := s.(ssh.AlgorithmSigner); ok {
				return as.SignWithAlgorithm(rand.Reader, data, alg)
			}
		}
	}
	return s.Sign(rand.Reader, data)
}

func (a *Agent) LoadFile(path string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	signer, err := parseSigner(string(b))
	if err != nil {
		return err
	}
	pub := signer.PublicKey()
	a.SetKeys([]*Key{{
		ID:          "mock",
		Name:        "mock key",
		Signer:      signer,
		PublicKey:   pub,
		Fingerprint: sshFingerprint(pub),
	}})
	return nil
}

func (a *Agent) Warnings() []string {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return append([]string(nil), a.warnings...)
}
