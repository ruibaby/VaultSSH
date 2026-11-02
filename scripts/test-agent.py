#!/usr/bin/env python3
"""Exercise the real helper with disposable keys and inherited control pipes."""
import json
import os
from pathlib import Path
import queue
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
        helper_process = subprocess.Popen(
            [helper, "--socket", str(root / "agent.sock"), "--status", str(root / "status.json"),
             "--events", str(root / "events.jsonl"), "--mock-key", str(key)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
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
            successful(sign())  # Same caller/key is cached; no UI response.

            send({"type": "revoke"})
            wait_for(lambda m: m["type"] == "revoked")
            client = sign()
            wait_for(lambda m: m["type"] == "approval")
            helper_process.stdin.close()  # Parent disconnect must terminate the helper.
            helper_process.wait(timeout=5)
            client.communicate(timeout=5)
            assert client.returncode != 0, "Disconnected app still allowed signing"
            assert not (root / "agent.sock").exists(), "Socket survived helper exit"
            assert not (root / "session").exists(), "Session was written to disk"
            print("PASS: forged file rejected; deny, allow once, cached grant, revoke, OpenSSH verification and parent EOF")
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
