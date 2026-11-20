#!/usr/bin/env node
/**
 * Packs the SDK from the parent folder into vendor/kirora-react-native.tgz, which package.json
 * depends on. React Native only autolinks native modules that are listed in package.json, and
 * Metro does not follow symlinks well, so the example installs the SDK from a tarball.
 *
 *   npm run sdk && npm install
 */
const {execFileSync} = require('child_process');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const vendor = path.join(root, 'vendor');
fs.mkdirSync(vendor, {recursive: true});

// Run npm through node, so no shell is needed (and it works the same on Windows).
const npmCli = process.env.npm_execpath;
const [command, prefix] = npmCli ? [process.execPath, [npmCli]] : ['npm', []];
const output = execFileSync(command, [...prefix, 'pack', path.join(root, '..'), '--pack-destination', vendor, '--silent'], {
  cwd: root,
  encoding: 'utf8',
});
const packed = output.trim().split(/\r?\n/).pop();
fs.renameSync(path.join(vendor, packed), path.join(vendor, 'kirora-react-native.tgz'));
console.log(`Packed ${packed} to vendor/kirora-react-native.tgz`);
