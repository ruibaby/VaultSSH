#!/usr/bin/env python3
"""Exercise the real helper with disposable keys and inherited control pipes."""
import json
import os
from pathlib import Path
import queue
import resource
import socket
import subprocess
import sys
import tempfile
import threading
import time


def main(helper):
    with tempfile.TemporaryDirectory(prefix="vs-test-", dir="/tmp") as directory:
        root = Path(directory)
        key = root / "key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
        messages = queue.Queue()
        def limit_descriptors():
            resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))

        helper_process = subprocess.Popen(
            [helper, "--socket", str(root / "agent.sock"), "--status", str(root / "status.json"),
             "--events", str(root / "events.jsonl"), "--mock-key", str(key)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            preexec_fn=limit_descriptors,
        )
        clients = []

        def read_messages():
            for line in helper_process.stdout:
                messages.put(json.loads(line))

        threading.Thread(target=read_messages, daemon=True).start()

        def send(command):
            helper_process.stdin.write(json.dumps(command) + "\n")
            helper_process.stdin.flush()

        def wait_for(predicate, timeout=5):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                try:
                    message = messages.get(timeout=max(0.01, deadline - time.monotonic()))
                except queue.Empty:
                    break
                if predicate(message):
                    return message
            raise AssertionError("Expected helper message did not arrive")

        def sign():
            environment = os.environ.copy()
            environment["SSH_AUTH_SOCK"] = str(root / "agent.sock")
            client = subprocess.Popen(["ssh-add", "-T", str(key) + ".pub"], env=environment,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            clients.append(client)
            return client

        def decision(request, allow, seconds=0):
            send({"type": "decision", "decision": {"id": request["id"], "allow": allow, "graceSeconds": seconds}})

        def successful(client):
            _, error = client.communicate(timeout=5)
            assert client.returncode == 0, error

        try:
            send({"type": "session", "session": "mock"})
            wait_for(lambda m: m.get("status", {}).get("state") == "ready")
            # Only the inherited control pipe can set the window, and the helper
            # rejects values it does not offer instead of widening the grant.
            for requested, applied in [(1800, 1800), (301, 1800), (3601, 1800),
                                       (0, 1800), (-1, 1800), (3600, 3600), (300, 300)]:
                send({"type": "approvalWindow", "graceSeconds": requested})
                ack = wait_for(lambda m: m["type"] == "approvalWindow")
                assert ack["graceSeconds"] == applied, (requested, ack)
            # Connection exhaustion must reject excess clients without killing the helper.
            sockets = []
            try:
                for _ in range(96):
                    connection = socket.socket(socket.AF_UNIX)
                    connection.settimeout(2)
                    connection.connect(str(root / "agent.sock"))
                    sockets.append(connection)
                assert helper_process.poll() is None, "Idle sockets killed the helper"
            finally:
                for connection in sockets:
                    connection.close()
            time.sleep(0.1)
            # A non-interpreter launcher makes the caller cacheable, so the
            # cached log can be checked against the grant's real expiry. Widen
            # the setting before the second signature: the log must still show
            # the remaining 30 minutes, not the new 60-minute window.
            launcher_source = root / "launcher.go"
            launcher = root / "launcher"
            launcher_source.write_text(
                "package main\n"
                "\n"
                "import (\n"
                "  \"os\"\n"
                "  \"os/exec\"\n"
                ")\n"
                "\n"
                "func main() {\n"
                "  if len(os.Args) < 2 { os.Exit(2) }\n"
                "  cmd := exec.Command(os.Args[1], os.Args[2:]...)\n"
                "  cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr\n"
                "  if err := cmd.Run(); err != nil {\n"
                "    if exit, ok := err.(*exec.ExitError); ok { os.Exit(exit.ExitCode()) }\n"
                "    os.Exit(1)\n"
                "  }\n"
                "}\n"
            )
            subprocess.run(["go", "build", "-o", str(launcher), str(launcher_source)], check=True)

            def sign_cached():
                environment = os.environ.copy()
                environment["SSH_AUTH_SOCK"] = str(root / "agent.sock")
                client = subprocess.Popen([str(launcher), "/usr/bin/ssh-add", "-T", str(key) + ".pub"],
                                          env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                clients.append(client)
                return client

            send({"type": "approvalWindow", "graceSeconds": 1800})
            assert wait_for(lambda m: m["type"] == "approvalWindow")["graceSeconds"] == 1800
            client = sign_cached()
            request = wait_for(lambda m: m["type"] == "approval")["request"]
            assert request["cacheAllowed"] is True, "Non-interpreter caller was not cacheable"
            decision(request, True, 1800)
            successful(client)

            send({"type": "approvalWindow", "graceSeconds": 3600})
            assert wait_for(lambda m: m["type"] == "approvalWindow")["graceSeconds"] == 3600
            client = sign_cached()
            try:
                _, error = client.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                raise AssertionError("Cached grant requested another approval") from None
            assert client.returncode == 0, error
            deadline = time.monotonic() + 2
            cached = []
            while not cached and time.monotonic() < deadline:
                events = [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines() if line]
                cached = [event for event in events if event.get("reason") == "cached"]
                if not cached:
                    time.sleep(0.02)
            assert cached, "Missing cached activity event"
            seconds = cached[-1]["graceSeconds"]
            assert 1790 <= seconds <= 1800, f"cached log says {seconds}s, expected the original ~1800s grant"
            assert "60 minutes" not in cached[-1]["detail"], cached[-1]["detail"]
            send({"type": "revoke"})
            wait_for(lambda m: m["type"] == "revoked")
            send({"type": "approvalWindow", "graceSeconds": 300})
            assert wait_for(lambda m: m["type"] == "approvalWindow")["graceSeconds"] == 300

            client = sign()
            request = wait_for(lambda m: m["type"] == "approval")["request"]
            # The old attack surface must have no effect on the new helper.
            (root / "approval-decision.json").write_text(json.dumps({"id": request["id"], "allow": True, "graceSeconds": 300}))
            time.sleep(0.15)
            assert client.poll() is None, "Untrusted decision file authorized signing"
            decision(request, False)
            client.communicate(timeout=5)
            assert client.returncode != 0, "Denied signature unexpectedly succeeded"

            client = sign()
            request = wait_for(lambda m: m["type"] == "approval")["request"]
            decision(request, True)
            successful(client)  # OpenSSH verifies the signature against the public key.
            client = sign()
            request = wait_for(lambda m: m["type"] == "approval")["request"]
            decision(request, True, 300)
            successful(client)
            assert request["cacheAllowed"] is False, "Python parent must not share a cached grant"
            client = sign()
            request = wait_for(lambda m: m["type"] == "approval")["request"]
            decision(request, True)
            successful(client)

            client = sign()
            wait_for(lambda m: m["type"] == "approval")
            send({"type": "revoke"})
            wait_for(lambda m: m["type"] == "revoked")
            client.communicate(timeout=5)
            assert client.returncode != 0, "Clear all approvals did not invalidate the pending request"

            client = sign()
            wait_for(lambda m: m["type"] == "approval")
            helper_process.stdin.close()  # Parent disconnect must terminate the helper.
            helper_process.wait(timeout=5)
            client.communicate(timeout=5)
            assert client.returncode != 0, "Disconnected app still allowed signing"
            assert not (root / "agent.sock").exists(), "Socket survived helper exit"
            assert not (root / "session").exists(), "Session was written to disk"
            print("PASS: approval window validation and cached remaining lifetime; forged file rejected; deny, allow once, interpreter grant isolation, connection cap, clear all approvals, OpenSSH verification and parent EOF")
        finally:
            for client in clients:
                if client.poll() is None:
                    client.kill()
                client.wait()
            if helper_process.poll() is None:
                helper_process.kill()
            helper_process.wait()


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).resolve()))
