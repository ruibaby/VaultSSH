package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"

	"golang.org/x/crypto/ssh"
)

const (
	agentFailure          = 5
	agentcRequestIdentity = 11
	agentIdentitiesAnswer = 12
	agentcSignRequest     = 13
	agentSignResponse     = 14
	agentcLock            = 22
	agentcUnlock          = 23
	agentcExtension       = 27
	agentExtensionFailure = 28
	maxAgentMessage       = 1 << 20
)

type signRequestMsg struct {
	KeyBlob []byte
	Data    []byte
	Flags   uint32
}

type signResponseMsg struct {
	Signature []byte
}

func encodeIdentities(keys []*Key) []byte {
	out := []byte{agentIdentitiesAnswer}
	var n [4]byte
	binary.BigEndian.PutUint32(n[:], uint32(len(keys)))
	out = append(out, n[:]...)
	for _, k := range keys {
		out = appendSSHString(out, k.PublicKey.Marshal())
		out = appendSSHString(out, []byte(k.Name))
	}
	return out
}

func appendSSHString(dst, s []byte) []byte {
	var n [4]byte
	binary.BigEndian.PutUint32(n[:], uint32(len(s)))
	dst = append(dst, n[:]...)
	return append(dst, s...)
}

func readMessage(r io.Reader) ([]byte, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(lenBuf[:])
	if n == 0 {
		return nil, errors.New("empty agent message")
	}
	if n > maxAgentMessage {
		return nil, fmt.Errorf("agent message too large: %d", n)
	}
	msg := make([]byte, n)
	if _, err := io.ReadFull(r, msg); err != nil {
		return nil, err
	}
	return msg, nil
}

func writeMessage(w io.Writer, msg []byte) error {
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(msg)))
	if _, err := w.Write(lenBuf[:]); err != nil {
		return err
	}
	_, err := w.Write(msg)
	return err
}

func writeFailure(w io.Writer) error          { return writeMessage(w, []byte{agentFailure}) }
func writeExtensionFailure(w io.Writer) error { return writeMessage(w, []byte{agentExtensionFailure}) }

func handleConn(conn net.Conn, a *Agent, events *EventLogger, approver *Approver) {
	defer conn.Close()
	peer := resolvePeer(conn)
	for {
		msg, err := readMessage(conn)
		if err != nil {
			if !errors.Is(err, io.EOF) && !isClosed(err) {
				events.Event(peerEvent("error", peer, "", "", "error", localized("Could not read request: ")+err.Error()))
			}
			return
		}
		switch msg[0] {
		case agentcRequestIdentity:
			keys := a.Keys()
			if err := writeMessage(conn, encodeIdentities(keys)); err != nil {
				return
			}
			events.Event(peerEvent("list", peer, "", "", "ok", fmt.Sprintf(localized("Keys: %d"), len(keys))))
		case agentcSignRequest:
			var req signRequestMsg
			if err := ssh.Unmarshal(msg[1:], &req); err != nil {
				_ = writeFailure(conn)
				events.Event(peerEvent("error", peer, "", "", "error", localized("Could not parse signing request: ")+err.Error()))
				continue
			}
			key := a.Find(req.KeyBlob)
			if key == nil {
				_ = writeFailure(conn)
				events.Event(peerEvent("error", peer, "", "", "error", localized("An unknown key was requested.")))
				continue
			}
			allowed, reason := approver.Approve(peer, key)
			if !allowed {
				_ = writeFailure(conn)
				events.Event(approvalEvent(peer, key, "denied", reason))
				continue
			}
			sig, err := signWithFlags(key.Signer, req.Data, req.Flags)
			if err != nil {
				_ = writeFailure(conn)
				events.Event(peerEvent("sign", peer, key.Name, key.Fingerprint, "error", err.Error()))
				continue
			}
			resp := append([]byte{agentSignResponse}, ssh.Marshal(&signResponseMsg{Signature: ssh.Marshal(sig)})...)
			if err := writeMessage(conn, resp); err != nil {
				return
			}
			events.Event(approvalEvent(peer, key, "ok", reason))
		case agentcExtension:
			_ = writeExtensionFailure(conn)
		case agentcLock, agentcUnlock:
			// The app owns locking; do not pretend to support passphrase locks.
			_ = writeFailure(conn)
		default:
			_ = writeFailure(conn)
		}
	}
}

func approvalEvent(peer PeerInfo, key *Key, result, reason string) Event {
	event := peerEvent("sign", peer, key.Name, key.Fingerprint, result, approvalMessage(reason))
	event.Reason = reason
	return event
}

func peerEvent(kind string, p PeerInfo, keyName, fingerprint, result, detail string) Event {
	return Event{
		Type:          kind,
		PID:           p.PID,
		Process:       p.Process,
		Executable:    p.Executable,
		ParentPID:     p.ParentPID,
		ParentProcess: p.ParentProcess,
		KeyName:       keyName,
		Fingerprint:   fingerprint,
		Result:        result,
		Detail:        detail,
	}
}

func isClosed(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "use of closed network connection") ||
		strings.Contains(s, "connection reset by peer")
}
