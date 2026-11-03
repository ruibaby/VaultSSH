'use strict';
// Run against an installed locked runtime, always with a disposable account directory.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const bridge = path.resolve(__dirname, '../Sources/VaultSSH/Resources/CLI/bridge.cjs');
const entry = path.resolve(process.argv[2]);
const version = require('../Sources/VaultSSH/Resources/CLI/package.json').dependencies['@bitwarden/cli'];
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'vs-cli-account-'));
try {
  function command(operation, credentials = {}) {
    return spawnSync(process.execPath, [bridge, entry, operation], {
      input: JSON.stringify(credentials), encoding: 'utf8', timeout: 30000,
      env: {PATH: process.env.PATH, HOME: directory, BITWARDENCLI_APPDATA_DIR: directory},
    });
  }
  const info = command('version');
  assert.equal(info.status, 0, info.stderr);
  assert.equal(info.stdout.trim(), version);
  const status = command('status');
  assert.equal(status.status, 0, status.stderr);
  assert.equal(JSON.parse(status.stdout).status, 'unauthenticated');
  for (const operation of ['unlock', 'list']) {
    const result = command(operation, {password: 'disposable-password', session: 'disposable-session'});
    assert.notEqual(result.status, 0);
    assert.ok(!result.stderr.includes('disposable-'));
  }
  console.log('PASS: locked npm runtime version, isolated status and unauthenticated failures');
} finally {
  fs.rmSync(directory, {recursive: true, force: true});
}
