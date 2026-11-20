// A stand-in for Kirora's client API (`/client/v1`), for end-to-end tests of the e2e app. It
// answers as `omnichannel/openapi.json` describes, and records every request so a test can check
// exactly what the native SDK sent. No dependencies: `node e2e/fake-kirora.mjs`.
//
// Test control, under /__test:
//   GET  /__test/requests[?path=<substring>]   the recorded requests, oldest first
//   POST /__test/reset                          forget requests and refused tokens
//   POST /__test/tokens {"refused": ["token", ...]}
//                                               these user tokens always get 401

import http from 'node:http';

const PORT = Number(process.env.FAKE_KIRORA_PORT ?? 4010);
const PUSH_APP_ID = 'pa_e2e_android';

let requests = [];
let refusedTokens = new Set();

function send(res, status, body) {
  if (body === undefined) {
    res.writeHead(status).end();
    return;
  }
  res.writeHead(status, { 'content-type': 'application/json' }).end(JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      if (!text) return resolve(undefined);
      try {
        resolve(JSON.parse(text));
      } catch {
        resolve(text);
      }
    });
  });
}

function control(req, res, url, body) {
  if (req.method === 'GET' && url.pathname === '/__test/requests') {
    const filter = url.searchParams.get('path');
    return send(res, 200, filter ? requests.filter((r) => r.path.includes(filter)) : requests);
  }
  if (req.method === 'POST' && url.pathname === '/__test/reset') {
    requests = [];
    refusedTokens = new Set();
    return send(res, 204);
  }
  if (req.method === 'POST' && url.pathname === '/__test/tokens') {
    refusedTokens = new Set(body.refused ?? []);
    return send(res, 204);
  }
  return send(res, 404, { error: 'unknown test control' });
}

// The client API's answers, as the native SDKs expect them.
function answer(req, res, path, body) {
  const m = req.method;
  if (m === 'GET' && path === '/client/v1/push-app') {
    return send(res, 200, { data: { pushAppId: PUSH_APP_ID, name: 'E2E', targetKind: 'fcm' } });
  }
  if (m === 'PUT' && /^\/client\/v1\/devices\/[^/]+$/.test(path)) {
    return send(res, 200, { data: { lastSeenAt: new Date().toISOString() } });
  }
  if (m === 'DELETE' && /^\/client\/v1\/devices\/[^/]+$/.test(path)) return send(res, 204);
  if (m === 'POST' && /^\/client\/v1\/devices\/[^/]+\/app-opens$/.test(path)) return send(res, 204);
  if (m === 'PUT' && path === '/client/v1/push-consent') return send(res, 204);
  if (m === 'POST' && path === '/client/v1/events/batch') {
    // One result per event, in order: the SDK settles each event by its own result (matched by
    // idempotency key) and retries any that has none.
    const expiresAt = new Date(Date.now() + 365 * 86_400_000).toISOString();
    const results = (body?.events ?? []).map((e, i) => ({
      idempotencyKey: e.idempotencyKey ?? null,
      replayed: false,
      event: { id: `evt_e2e_${requests.length}_${i}`, occurredAt: e.occurredAt ?? new Date().toISOString(), expiresAt }
    }));
    return send(res, 200, { data: { results } });
  }
  if (m === 'POST' && path.startsWith('/track/')) return send(res, 204);
  return send(res, 404, { error: { code: 'not_found', message: `${m} ${path}` } });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const body = await readBody(req);
  if (url.pathname.startsWith('/__test/')) return control(req, res, url, body ?? {});

  const authorization = req.headers.authorization ?? null;
  requests.push({
    method: req.method,
    path: url.pathname,
    clientKey: req.headers['kirora-client-key'] ?? null,
    sdk: req.headers['kirora-sdk'] ?? null,
    authorization,
    body
  });

  const token = authorization?.replace(/^Bearer\s+/i, '');
  if (token && refusedTokens.has(token)) {
    return send(res, 401, { error: { code: 'invalid_user_token', message: 'refused by the test' } });
  }
  return answer(req, res, url.pathname, body);
});

server.listen(PORT, () => console.log(`fake Kirora listening on http://localhost:${PORT}`));
