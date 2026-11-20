// Runs the e2e app's end-to-end scenarios on an Android emulator, after `e2e/android.sh`
// installed it (with its JS bundle inside) and started the fake API. It taps the harness buttons in `App.tsx` by
// their accessibilityLabel, waits for the `[e2e] <button>: ok|error` line the app logs, and checks
// what reached `e2e/fake-kirora.mjs`. Usage, from `e2e-app/`: node e2e/android.mjs [scenario...]
// With several devices attached, pick one with ANDROID_SERIAL (e.g. emulator-5554).
import { execFileSync, spawn } from 'node:child_process';

const ADB = `${process.env.ANDROID_HOME ?? `${process.env.HOME}/Library/Android/sdk`}/platform-tools/adb`;
const SERIAL = process.env.ANDROID_SERIAL ? ['-s', process.env.ANDROID_SERIAL] : [];
const API = `http://localhost:${process.env.FAKE_KIRORA_PORT ?? 4010}`;
const APP = 'com.kiroraexample';
const STARTUP_MS = 60_000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const adb = (...args) => execFileSync(ADB, [...SERIAL, ...args], { encoding: 'utf8', maxBuffer: 32 << 20 });

async function api(path, body) {
  const init = body === undefined ? {} : { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) };
  const res = await fetch(API + path, init);
  return res.status === 204 ? undefined : res.json();
}
/** The event batches the fake API received, oldest first. */
const batches = () => api('/__test/requests?path=/events/batch');
/** The events those batches carried. */
const sentEvents = async () => (await batches()).flatMap((r) => r.body.events);
const sentNames = async () => (await sentEvents()).map((e) => e.name);

// ---- The app's `[e2e]` log lines, read from one logcat stream per app start.

let lines = [];
let logcat;
function followLog() {
  logcat?.kill();
  adb('logcat', '-c');
  lines = [];
  logcat = spawn(ADB, [...SERIAL, 'logcat', '-s', 'ReactNativeJS:V', '-v', 'raw']);
  let rest = '';
  logcat.stdout.setEncoding('utf8').on('data', (chunk) => {
    const parts = (rest + chunk).split('\n');
    rest = parts.pop();
    for (const p of parts) if (p.trim().startsWith('[e2e] ')) lines.push(p.trim().slice(6));
  });
}

/** The first line from index `since` on that `match` accepts. */
async function waitForLine(match, timeout, since = 0) {
  const until = Date.now() + timeout;
  for (;;) {
    const line = lines.slice(since).find(match);
    if (line) return line;
    if (Date.now() > until) throw new Error(`no matching log line in ${timeout} ms; last: ${lines.slice(-5).join(' | ')}`);
    await sleep(100);
  }
}

// ---- Buttons: read once the app's screen has settled after each start.

let buttons;
function findButtons() {
  const xml = adb('exec-out', 'uiautomator', 'dump', '/dev/tty');
  buttons = {};
  for (const m of xml.matchAll(/content-desc="([^"]+)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/g)) {
    buttons[m[1]] = [(+m[2] + +m[4]) >> 1, (+m[3] + +m[5]) >> 1];
  }
}

/** Taps a button and answers its `id: …` line; `expect` (a prefix of what follows) or null to accept any. */
async function tap(id, { expect = 'ok', timeout = 15_000 } = {}) {
  if (!buttons[id]) findButtons();
  if (!buttons[id]) throw new Error(`no button ${id}`);
  const since = lines.length;
  adb('shell', 'input', 'tap', String(buttons[id][0]), String(buttons[id][1]));
  const line = await waitForLine((l) => l.startsWith(`${id}: `), timeout, since);
  if (expect !== null && !line.startsWith(`${id}: ${expect}`)) throw new Error(`${id}: expected "${expect}", got "${line}"`);
  return line;
}

/** Taps each button in turn, each answering `ok`. */
async function taps(...ids) {
  for (const id of ids) await tap(id);
}

function check(cond, message, detail) {
  if (!cond) throw new Error(`${message}\n  got: ${String(JSON.stringify(detail)).slice(0, 600)}`);
}

/** A cold start with clean storage and a clean fake API. */
async function freshApp() {
  await api('/__test/reset', {});
  adb('shell', 'pm', 'clear', APP);
  adb('shell', 'pm', 'grant', APP, 'android.permission.POST_NOTIFICATIONS');
  followLog();
  adb('shell', 'am', 'start', '-W', '-n', `${APP}/.MainActivity`);
  await waitForLine((l) => l.startsWith('sdk '), STARTUP_MS);
  await settledButtons();
}

/** Reads the buttons until two reads agree: banners shown at start move them at first. */
async function settledButtons() {
  let before = '';
  for (let i = 0; i < 20; i++) {
    findButtons();
    const now = JSON.stringify(buttons);
    if (buttons.start && now === before) return;
    before = now;
    await sleep(500);
  }
  throw new Error('the app\'s buttons never settled');
}

const scenarios = {
  async setupAndHeaders() {
    await tap('start', { expect: 'ok available=true' });
    await tap('identifyA');
    await tap('track');
    await tap('flush');
    const [first] = await batches();
    check(first, 'events were sent', first);
    check(first.clientKey === 'kirora_pk_e2e', 'client key header', first.clientKey);
    check(/^kirora-react-native\/\d/.test(first.sdk ?? ''), 'Kirora-SDK names the wrapper', first.sdk);
    check(first.authorization === 'Bearer e2e-token-user-a', 'user token sent', first.authorization);
  },

  async beforeSendRedactsAndDrops() {
    // Events before sign-in wait on the device: these scenarios sign in to see them sent.
    await taps('start', 'identifyA');
    await taps('track', 'trackDropped', 'trackScreen', 'trackProto', 'flush');
    const events = await sentEvents();
    const names = events.map((e) => e.name);
    check(names.includes('E2E Tapped'), 'tracked event sent', names);
    check(!names.includes('E2E Dropped'), 'beforeSend null drops it', names);
    check(names.includes('Screen Viewed'), 'screen view sent through beforeSend', names);
    const tapped = events.find((e) => e.name === 'E2E Tapped');
    check(!JSON.stringify(tapped).includes('x@example.com'), 'email redacted', tapped);
    check(tapped.properties.nested !== undefined, 'nested properties kept', tapped);
    const proto = events.find((e) => e.name === 'E2E Proto');
    check(proto?.properties.order_id === 'ORD-1042', 'proto event keeps its properties', proto);
  },

  async consentRefusedBlocksEvents() {
    await taps('start', 'identifyA');
    await taps('consentOff', 'track', 'flush');
    let names = await sentNames();
    check(!names.includes('E2E Tapped'), 'no event while consent refused', names);
    await taps('consentOn', 'track', 'flush');
    names = await sentNames();
    check(names.includes('E2E Tapped'), 'events again once granted', names);
  },

  async requireConsentAndRemembered() {
    await taps('startConsent', 'identifyA');
    await taps('track', 'flush');
    let names = await sentNames();
    check(!names.includes('E2E Tapped'), 'nothing before consent', names);
    await taps('consentOn', 'track', 'flush');
    names = await sentNames();
    check(names.includes('E2E Tapped'), 'sent after consent', names);
    // A new client: the remembered grant comes from setup's answer.
    await api('/__test/reset', {});
    await taps('startConsent', 'identifyA', 'track', 'flush');
    names = await sentNames();
    check(names.includes('E2E Tapped'), 'remembered grant allows tracking on a new client', names);
  },

  async refusalThenReplacement() {
    await taps('start', 'replaceAfterRefusal', 'track', 'flush');
    const names = await sentNames();
    check(!names.includes('E2E Tapped'), 'refusal survives the replacement', names);
    const state = await tap('state');
    check(state.includes('"trackingConsent":false'), 'state says refused', state);
  },

  async identityAndLogout() {
    await taps('start', 'identifyA', 'track', 'identifyB', 'track', 'flush');
    const auths = (await batches()).map((r) => r.authorization);
    check(auths.includes('Bearer e2e-token-user-a') && auths.includes('Bearer e2e-token-user-b'), 'each user sends with own token', auths);
    await tap('logout');
    const state = await tap('state');
    check(state.includes('"isIdentified":false'), 'signed out', state);
  },

  async identifyWithoutToken() {
    // A refused token can't fail identify() here: it awaits only its push registration, which
    // needs Firebase. A refusal is reported through onAuthenticationFailed (backgroundAuthFailure).
    await taps('start', 'sessionNone');
    const none = await tap('identifyFetch', { expect: 'error' });
    check(/UserTokenError/.test(none), 'no token: UserTokenError', none);
  },

  async backgroundAuthFailure() {
    await taps('start', 'identifyA', 'sessionRefused');
    await api('/__test/tokens', { refused: ['e2e-token-user-a', 'e2e-token-refused'] });
    const since = lines.length;
    for (const id of ['track', 'flush']) await tap(id, { expect: null });
    const line = await waitForLine((l) => l.startsWith('authFailed: '), 15_000, since);
    check(line === 'authFailed: refused', 'reason refused', line);
  },

  async pushCalls() {
    await tap('start');
    const status = await tap('pushStatus');
    check(/"(enabled|disabled|denied|unanswered|unsupported)"/.test(status), 'push status is a spec value', status);
    const permission = await tap('requestPermission');
    check(/"(granted|denied|unanswered|unsupported)"/.test(permission), 'permission is a spec value', permission);
    await tap('identifyA');
    // Without Firebase there's no push token: recording the choice may fail, but must answer.
    await tap('pushConsentOn', { expect: null });
    await tap('pushEnabledOff');
    await tap('pushEnabledOn');
  },

  async destroyKeepsWaitingEvents() {
    await taps('start', 'track', 'destroy');
    await tap('state', { expect: 'error no client' });
    await taps('start', 'identifyA', 'flush');
    const names = await sentNames();
    check(names.includes('E2E Tapped'), 'an event waiting at destroy is sent by the next client', names);
  }
};

const chosen = process.argv.length > 2 ? process.argv.slice(2) : Object.keys(scenarios);
let failed = 0;
try {
  for (const name of chosen) {
    try {
      await freshApp();
      await scenarios[name]();
      console.log(`PASS ${name}`);
    } catch (e) {
      failed++;
      console.log(`FAIL ${name}: ${e.message}`);
    }
  }
} finally {
  logcat?.kill();
}
console.log(`${chosen.length - failed}/${chosen.length} passed`);
process.exit(failed ? 1 : 0);
