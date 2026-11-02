package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"io"
	"reflect"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func TestKeyOrderProtocol(t *testing.T) {
	var keys []*Key
	for _, name := range []string{"other-mac", "this-mac", "new-key"} {
		_, private, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		signer, err := ssh.NewSignerFromKey(private)
		if err != nil {
			t.Fatal(err)
		}
		keys = append(keys, testKey(name, name, signer))
	}
	a := NewAgent()
	// Saved preferences arrive before keys load; deleted and duplicate entries
	// must not hide keys or disturb the remaining vault order.
	a.SetKeyOrder([]string{"missing", keys[1].Fingerprint, keys[1].Fingerprint})
	a.SetKeys(keys)
	client := startTestServer(t, a)
	check := func(want []string) {
		t.Helper()
		listed, err := client.List()
		if err != nil {
			t.Fatal(err)
		}
		var got []string
		for _, key := range listed {
			got = append(got, key.Comment)
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("SSH identities = %v, want %v", got, want)
		}
		data := []byte("ordered key signing")
		signature, err := client.Sign(listed[0], data)
		if err != nil {
			t.Fatal(err)
		}
		pub, err := ssh.ParsePublicKey(listed[0].Blob)
		if err != nil {
			t.Fatal(err)
		}
		if err := pub.Verify(data, signature); err != nil {
			t.Fatal(err)
		}
	}
	check([]string{"this-mac", "other-mac", "new-key"})
	a.SetKeys([]*Key{keys[2], keys[0], keys[1]})
	check([]string{"this-mac", "new-key", "other-mac"})
	a.SetKeyOrder([]string{keys[0].Fingerprint, keys[1].Fingerprint, keys[2].Fingerprint})
	check([]string{"other-mac", "this-mac", "new-key"})
	a.SetKeyOrder(nil)
	check([]string{"new-key", "other-mac", "this-mac"})
}

func TestKeyOrderControlHandshakeAndUpdate(t *testing.T) {
	r, w := io.Pipe()
	out, output := io.Pipe()
	c := NewControlChannel(r, output, func() {})
	defer c.Close()
	defer r.Close()
	defer w.Close()
	defer out.Close()
	defer output.Close()
	a := NewAgent()
	_, private, _ := ed25519.GenerateKey(rand.Reader)
	signer, _ := ssh.NewSignerFromKey(private)
	a.SetKeys([]*Key{testKey("a", "A", signer), testKey("b", "B", signer)})
	// Distinct IDs with synthetic fingerprints suffice for control ordering.
	a.keys[0].Fingerprint = "first"
	a.keys[1].Fingerprint = "second"
	go func() {
		_, _ = io.Copy(w, strings.NewReader("{\"type\":\"session\",\"session\":\"mock\",\"keyOrder\":[\"second\",\"first\"]}\n"))
	}()
	session, order, err := c.ReadSession()
	if err != nil || session != "mock" {
		t.Fatalf("handshake: %q %v", session, err)
	}
	a.SetKeyOrder(order)
	if a.KeyInfos()[0].ID != "b" {
		t.Fatal("startup order ignored")
	}
	approver := NewApprover(time.Second, c.Send)
	go c.ReadCommands(approver, a)
	_, err = io.Copy(w, bytes.NewBufferString("{\"type\":\"keyOrder\",\"keyOrder\":[\"first\",\"second\"]}\n"))
	if err != nil {
		t.Fatal(err)
	}
	var event ControlEvent
	if err := json.NewDecoder(out).Decode(&event); err != nil {
		t.Fatal(err)
	}
	if event.Type != "keys" || len(event.Keys) != 2 || event.Keys[0].ID != "a" {
		t.Fatalf("wrong acknowledged order: %+v", event)
	}
}
