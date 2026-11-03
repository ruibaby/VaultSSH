#!/usr/bin/env python3
"""Locked socket -> explicit unlock -> separate SSH approval, using disposable keys."""
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
    with tempfile.TemporaryDirectory(prefix='vs-locked-', dir='/tmp') as directory:
        root = Path(directory)
        key = root / 'key'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
        process = subprocess.Popen([helper, '--locked', '--mock-key', str(key),
                                    '--socket', str(root / 'agent.sock'), '--status', str(root / 'status.json'),
                                    '--events', str(root / 'events.jsonl')],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        messages = queue.Queue()
        clients = []
        def read():
            for line in process.stdout:
                messages.put(json.loads(line))
        threading.Thread(target=read, daemon=True).start()
        def send(value):
            process.stdin.write(json.dumps(value) + '\n')
            process.stdin.flush()
        def wait(predicate):
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                message = messages.get(timeout=max(0.01, deadline - time.monotonic()))
                if predicate(message): return message
            raise AssertionError('missing control event')
        def wait_status(state):
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if json.loads((root / 'status.json').read_text())['state'] == state:
                    return
                time.sleep(0.01)
            raise AssertionError('status file did not reach ' + state)
        def client(*args):
            environment = os.environ.copy()
            environment['SSH_AUTH_SOCK'] = str(root / 'agent.sock')
            result = subprocess.Popen(['ssh-add', *args], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            clients.append(result)
            return result
        try:
            send({'type': 'session', 'session': ''})
            wait(lambda e: e.get('status', {}).get('state') == 'locked')
            listing = client('-l')
            request = wait(lambda e: e['type'] == 'unlock')['request']
            assert listing.poll() is None
            assert json.loads((root / 'status.json').read_text())['state'] == 'locked'
            send({'type': 'cancelUnlock', 'id': request['id']})
            listing.communicate(timeout=5)
            assert listing.returncode != 0, 'cancelled unlock exposed identities'
            send({'type': 'unlock', 'id': request['id'], 'session': 'late-mock'})
            wait(lambda e: e.get('status', {}).get('state') == 'locked')
            assert json.loads((root / 'status.json').read_text())['state'] == 'locked'
            # Explicit manual unlock can override prompt cooldown; socket clients cannot.
            send({'type': 'unlock', 'session': 'mock'})
            wait(lambda e: e.get('status', {}).get('state') == 'ready')
            wait_status('ready')
            signing = client('-T', str(key) + '.pub')
            approval = wait(lambda e: e['type'] == 'approval')['request']
            assert signing.poll() is None, 'unlock implicitly approved signing'
            send({'type': 'decision', 'decision': {'id': approval['id'], 'allow': True}})
            signing.communicate(timeout=5)
            assert signing.returncode == 0, 'signature verification failed'
            process.stdin.close()
            process.wait(timeout=5)
            assert not (root / 'agent.sock').exists()
            print('PASS: locked socket prompts; cancel and late unlock denied; unlock needs separate signing approval; parent EOF')
        finally:
            for child in clients:
                if child.poll() is None: child.kill()
                child.wait()
            if process.poll() is None: process.kill()
            process.wait()


if __name__ == '__main__':
    main(str(Path(sys.argv[1]).resolve()))
