'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn, spawnSync} = require('node:child_process');
const bridge = path.resolve(__dirname, '../Sources/VaultSSH/Resources/CLI/bridge.cjs');
const runtime = require('../Sources/VaultSSH/Resources/CLI/package.json');
const version = runtime.dependencies['@bitwarden/cli'];

function fixture(t, source, supported = version) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vs-cli-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  fs.mkdirSync(path.join(root, 'build'));
  fs.writeFileSync(path.join(root, 'package.json'), JSON.stringify({name: '@bitwarden/cli', version: supported}));
  for (const [name, version] of Object.entries(runtime.overrides)) {
    const directory = path.join(root, 'node_modules', name);
    fs.mkdirSync(directory, {recursive: true});
    fs.writeFileSync(path.join(directory, 'package.json'), JSON.stringify({name, version}));
  }
  const entry = path.join(root, 'build/bw.js');
  fs.writeFileSync(entry, source);
  return entry;
}
function run(entry, operation, input = '{}', args = []) {
  return spawnSync(process.execPath, [bridge, entry, operation, ...args], {
    input, encoding: 'utf8', timeout: 5000,
    env: {PATH: process.env.PATH, HOME: os.tmpdir()},
  });
}

test('credentials remain absent from OS startup args and environment', async t => {
  const secret = 'dummy-only-' + Date.now();
  const entry = fixture(t, `
    if (process.env.BW_PASSWORD !== ${JSON.stringify(secret)}) process.exit(2);
    process.stdout.write('ready\\n');
    setTimeout(() => {}, 10000);
  `);
  const child = spawn(process.execPath, [bridge, entry, 'unlock'], {
    env: {PATH: process.env.PATH, HOME: os.tmpdir()}, stdio: ['pipe', 'pipe', 'pipe'],
  });
  t.after(() => child.kill());
  child.stdin.end(JSON.stringify({password: secret}));
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('bridge did not start')), 5000);
    child.stdout.once('data', data => { clearTimeout(timer); assert.equal(data.toString(), 'ready\n'); resolve(); });
    child.once('error', reject);
    child.once('exit', () => { clearTimeout(timer); reject(new Error('bridge exited early')); });
  });
  const snapshot = spawnSync('/bin/ps', ['eww', '-p', String(child.pid), '-o', 'command='], {encoding: 'utf8'});
  assert.equal(snapshot.status, 0);
  assert.ok(snapshot.stdout.includes('bridge.cjs'));
  assert.ok(!snapshot.stdout.includes(secret));
  assert.ok(!snapshot.stdout.includes('BW_PASSWORD='));
});

test('valid npm symlink, Unicode credentials and all vault operations', t => {
  const entry = fixture(t, `process.stdout.write(JSON.stringify({args: process.argv.slice(2), password: process.env.BW_PASSWORD, session: process.env.BW_SESSION}));`);
  const link = path.join(path.dirname(entry), 'bw-link');
  fs.symlinkSync(entry, link);
  const unlock = run(link, 'unlock', JSON.stringify({password: 'test-中文-🔐\nend'}));
  assert.equal(unlock.status, 0, unlock.stderr);
  assert.equal(JSON.parse(unlock.stdout).password, 'test-中文-🔐\nend');
  for (const operation of ['sync', 'list', 'get']) {
    const result = run(link, operation, JSON.stringify({session: 'fake-session'}), ['item-id']);
    assert.equal(result.status, 0, result.stderr);
    const output = JSON.parse(result.stdout);
    assert.equal(output.session, 'fake-session');
    assert.equal(output.password, undefined);
    assert.ok(output.args.includes('--nointeraction'));
  }
});

test('unsupported CLI, command and oversized/malformed inputs fail closed', t => {
  const entry = fixture(t, `process.stdout.write('executed');`);
  const unsupported = fixture(t, `process.stdout.write('executed');`, '0.0.0');
  for (const [target, operation, input] of [
    [unsupported, 'status', '{}'], [entry, 'export', '{}'], [entry, 'unlock', '{}'],
    [entry, 'list', 'null'], [entry, 'unlock', 'x'], [entry, 'unlock', 'x'.repeat(65537)],
  ]) {
    const result = run(target, operation, input);
    assert.equal(result.status, 1, result.stderr);
    assert.equal(result.stdout, '');
  }
});

test('CLI child processes are blocked and raw failures are redacted', t => {
  for (const code of [
    `require('node:child_process').spawnSync('/bin/echo', ['leaked']);`,
    `process.stderr.write(process.env.BW_SESSION); throw new Error(process.env.BW_SESSION);`,
  ]) {
    const entry = fixture(t, code);
    const result = run(entry, 'list', JSON.stringify({session: 'dummy-sensitive-value'}));
    assert.equal(result.status, 1);
    assert.equal(result.stdout, '');
    assert.ok(!result.stderr.includes('dummy-sensitive-value'));
    assert.ok(!result.stderr.includes('leaked'));
  }
});

test('matching CLI version with missing or unpatched dependencies is rejected', t => {
  for (const name of Object.keys(runtime.overrides)) {
    for (const missing of [false, true]) {
      const entry = fixture(t, `process.stdout.write('executed');`);
      const manifest = path.join(path.dirname(path.dirname(entry)), 'node_modules', name, 'package.json');
      if (missing) fs.unlinkSync(manifest);
      else fs.writeFileSync(manifest, JSON.stringify({name, version: '0.0.0'}));
      const result = run(entry, 'status');
      assert.equal(result.status, 1);
      assert.equal(result.stdout, '');
    }
  }
});
