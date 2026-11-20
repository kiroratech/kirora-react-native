#!/usr/bin/env node
/**
 * Signs a short-lived user token (HS256 JWT) and writes it into src/config.local.json.
 *
 *   KIRORA_TOKEN_SECRET=<your workspace token secret> node scripts/mint-token.js [userId] [hours]
 *
 * The secret is read from the environment only; it is never written to disk or bundled.
 * In a real app your own backend does this; the secret must never ship inside the app.
 */
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const secret = process.env.KIRORA_TOKEN_SECRET;
if (!secret) {
  console.error('Set KIRORA_TOKEN_SECRET to your workspace token secret first.');
  process.exit(1);
}

const userId = process.argv[2] || 'test-user-1';
const hours = Math.min(Number(process.argv[3]) || 6, 24);

const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const head = b64({alg: 'HS256', typ: 'JWT'});
const body = b64({sub: userId, iat: now, exp: now + hours * 3600});
const sig = crypto.createHmac('sha256', secret).update(`${head}.${body}`).digest('base64url');
const token = `${head}.${body}.${sig}`;

const dir = path.join(__dirname, '..', 'src');
const target = path.join(dir, 'config.local.json');
const base = fs.existsSync(target)
  ? JSON.parse(fs.readFileSync(target, 'utf8'))
  : JSON.parse(fs.readFileSync(path.join(dir, 'config.example.json'), 'utf8'));

base.userToken = token;
fs.writeFileSync(target, JSON.stringify(base, null, 2) + '\n');
console.log(`Wrote a ${hours}h token for "${userId}" to src/config.local.json`);
