'use strict';

// Credentials arrive only after Node starts, over inherited stdin. Do not exec
// another CLI process: its startup environment would expose them again.
const fs = require('node:fs');
const path = require('node:path');
const childProcess = require('node:child_process');
const runtime = require('./package.json');
const supportedVersion = runtime.dependencies['@bitwarden/cli'];
const [cliPath, operation, itemID] = process.argv.slice(2);
const operations = {
  version: ['--version'],
  status: ['--nointeraction', 'status'],
  unlock: ['--nointeraction', 'unlock', '--raw', '--passwordenv', 'BW_PASSWORD'],
  sync: ['--nointeraction', 'sync'],
  list: ['--nointeraction', 'list', 'items', '--raw'],
  get: ['--nointeraction', 'get', 'item', itemID, '--raw'],
};
function fail() {
  // Never echo upstream exceptions, arguments, or credentials into persistent logs.
  process.stderr.write('VaultSSH CLI bridge failed. Check the supported npm CLI and its login status.\n');
  process.exit(1);
}
process.on('uncaughtException', fail);
process.on('unhandledRejection', fail);

async function main() {
  if (!Object.hasOwn(operations, operation) || (operation === 'get' && (!itemID || itemID.startsWith('-')))) fail();
  const entry = fs.realpathSync(cliPath);
  const packageRoot = path.dirname(path.dirname(entry));
  const manifest = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'), 'utf8'));
  if (manifest.name !== '@bitwarden/cli' || manifest.version !== supportedVersion ||
      entry !== path.join(packageRoot, 'build', 'bw.js')) fail();
  // The upstream CLI pins older dependencies. A custom npm installation must
  // include the same security updates as the managed runtime before use.
  for (const [name, version] of Object.entries(runtime.overrides)) {
    const dependency = require.resolve(`${name}/package.json`, {paths: [packageRoot]});
    if (JSON.parse(fs.readFileSync(dependency, 'utf8')).version !== version) fail();
  }

  let input = '';
  process.stdin.setEncoding('utf8');
  for await (const chunk of process.stdin) {
    input += chunk;
    if (Buffer.byteLength(input) > 65536) fail();
  }
  const credentials = JSON.parse(input || '{}');
  for (const key of Object.keys(process.env)) {
    if (key.startsWith('BW_') || key === 'NODE_OPTIONS' || key === 'NODE_PATH') delete process.env[key];
  }
  if (operation === 'unlock') {
    if (typeof credentials.password !== 'string' || !credentials.password) fail();
    process.env.BW_PASSWORD = credentials.password;
  } else if (['sync', 'list', 'get'].includes(operation)) {
    if (typeof credentials.session !== 'string' || !credentials.session) fail();
    process.env.BW_SESSION = credentials.session;
  }

  // These noninteractive vault commands must not launch descendants carrying
  // the in-memory environment. This is a compatibility guard, not a sandbox
  // for a malicious CLI or native addon: the selected npm package is trusted.
  for (const method of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork']) {
    childProcess[method] = () => { throw new Error('CLI child processes are disabled'); };
  }
  // Discard CLI diagnostics, which can include credentials or account details.
  // A failed command gets a fixed error; stdout remains the private data pipe.
  const writeError = process.stderr.write.bind(process.stderr);
  process.stderr.write = (_chunk, encoding, callback) => {
    if (typeof encoding === 'function') encoding();
    else if (typeof callback === 'function') callback();
    return true;
  };
  process.on('exit', code => {
    if (code) writeError('VaultSSH CLI command failed. Check your login, password, server and network.\n');
  });
  process.argv = [process.execPath, entry, ...operations[operation]];
  require(entry);
}
main().catch(fail);
