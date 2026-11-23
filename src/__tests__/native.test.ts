import { EMPTY_STATE } from '../backend';
import { Kirora } from '../Kirora';
import { KiroraApiError, KiroraError, UserTokenError } from '../errors';
import type { NativeKiroraModule, NativeOptions } from '../NativeBackend';
import { SDK_VERSION } from '../version';

class FakeNative implements NativeKiroraModule {
  calls: Array<[string, ...unknown[]]> = [];
  configured?: NativeOptions;
  /** What `configure` answers for tracking; undefined answers nothing. */
  trackingConsent: boolean | undefined = true;
  identifyError?: { code: string; message: string; userInfo?: Record<string, unknown> };
  listeners = new Map<string, (e: any) => void>();

  async configure(o: NativeOptions) {
    this.configured = o;
    return this.trackingConsent === undefined ? undefined : { trackingConsent: this.trackingConsent };
  }
  async identify(token: string | null) {
    this.calls.push(['identify', token]);
    if (this.identifyError) throw Object.assign(new Error(this.identifyError.message), this.identifyError);
  }
  async logout() {
    this.calls.push(['logout']);
  }
  track(name: string, json: string | null) {
    this.calls.push(['track', name, json]);
  }
  trackScreenView(name: string) {
    this.calls.push(['trackScreenView', name]);
  }
  setTrackingConsent(g: boolean) {
    this.calls.push(['setTrackingConsent', g]);
  }
  async setPushConsent(g: boolean) {
    this.calls.push(['setPushConsent', g]);
  }
  async requestPushPermission() {
    return 'unanswered' as const;
  }
  async getPushStatus() {
    return 'enabled' as const;
  }
  async setPushEnabled(e: boolean) {
    this.calls.push(['setPushEnabled', e]);
  }
  async flush() {
    this.calls.push(['flush']);
  }
  async getState() {
    return {
      isInitialized: true,
      isIdentified: true,
      deviceId: 'dev',
      sessionId: null,
      pushToken: null,
      trackingConsent: true,
      pushConsent: false,
      queuedEventCount: 3
    };
  }
  onNewPushToken(t: string) {
    this.calls.push(['onNewPushToken', t]);
  }
  onPushRegistered(id: string) {
    this.calls.push(['onPushRegistered', id]);
  }
  resolveToken(id: string, token: string | null, error: string | null) {
    this.calls.push(['resolveToken', id, token, error]);
  }
  resolveAnswer(id: string, answer: boolean) {
    this.calls.push(['resolveAnswer', id, answer]);
  }
  destroy() {
    this.calls.push(['destroy']);
  }
  setNotificationEvents(clicked: boolean, received: boolean) {
    this.calls.push(['setNotificationEvents', clicked, received]);
  }
  addListener() {}
  removeListeners() {}
  emitter = {
    addListener: (name: string, l: (e: any) => void) => {
      this.listeners.set(name, l);
      // Like a real emitter, removing a subscription removes only that one.
      return { remove: () => this.listeners.get(name) === l && this.listeners.delete(name) };
    }
  };
}

let native: FakeNative;
const make = (options: Partial<ConstructorParameters<typeof Kirora>[0]> = {}) =>
  new Kirora({ clientKey: ' kirora_pk_n ', ...options }, { native: { module: native, emitter: native.emitter } });

beforeEach(() => {
  Kirora.resetForTesting();
  native = new FakeNative();
});
afterEach(() => jest.restoreAllMocks());
afterAll(() => Kirora.resetForTesting());

const tick = (ms = 5) => new Promise((r) => setTimeout(r, ms));
/** The names of the events that reached the native SDK. */
const tracked = () => native.calls.filter((c) => c[0] === 'track').map((c) => c[1]);
/** A client whose beforeSend keeps every event, recording the names it saw. */
const makeSeeing = (options: Partial<ConstructorParameters<typeof Kirora>[0]> = {}) => {
  const seen: string[] = [];
  return { k: make({ beforeSend: (e) => (seen.push(e.name), e), ...options }), seen };
};

test('the native SDK is configured with the options, key trimmed', async () => {
  const k = make({ push: { pushAppId: 'app_1' }, trackAppLifecycle: true, fetchUserToken: async () => 't' });
  await k.getState();
  expect(k.isAvailable).toBe(true);
  expect(native.configured).toEqual({
    clientKey: 'kirora_pk_n',
    apiUrl: 'https://api.kirora.io',
    push: true,
    pushAppId: 'app_1',
    requireTrackingConsent: false,
    trackSessions: true,
    trackAppLifecycle: true,
    logLevel: 'error',
    hasTokenProvider: true,
    hasAuthenticationFailedHandler: false,
    smallIcon: null,
    accentColor: null,
    defaultChannelId: null,
    defaultChannelName: null,
    hasForegroundHandler: false,
    hasDeepLinkHandler: false,
    sdkVersion: SDK_VERSION
  });
});

test('calls go straight to the native SDK, properties copied as JSON', async () => {
  const k = make({ logLevel: 'none' });
  await k.identify('tok');
  k.track('Order Completed', { id: 1, at: new Date(0) });
  // Not JSON: dropped with a diagnostic, never sent changed.
  k.track('Bad Props', { big: BigInt(5) });
  k.track('Cycle', (() => { const o: any = {}; o.self = o; return o; })());
  k.track('No Props');
  k.trackScreenView('Home');
  k.setTrackingConsent(true);
  k.setPushConsent(false);
  k.onNewPushToken('t1');
  k.onPushRegistered('fid1');
  await k.flush();
  await k.logout();

  expect(native.calls).toEqual([
    ['identify', 'tok'],
    ['track', 'Order Completed', '{"id":1,"at":"1970-01-01T00:00:00.000Z"}'],
    ['track', 'No Props', '{}'],
    ['trackScreenView', 'Home'],
    ['setTrackingConsent', true],
    ['setPushConsent', false],
    ['onNewPushToken', 't1'],
    ['onPushRegistered', 'fid1'],
    ['flush'],
    ['logout']
  ]);
  expect(await k.requestPushPermission()).toBe('unanswered');
  expect((await k.getState()).queuedEventCount).toBe(3);
});

test('a token failure in the native SDK is a UserTokenError', async () => {
  native.identifyError = { code: 'USER_TOKEN_ERROR', message: 'fetchUserToken failed' };
  await expect(make().identify()).rejects.toBeInstanceOf(UserTokenError);
});

test("identify() rejects with the native SDK's error: Kirora's refusal with its details, and setup errors", async () => {
  native.identifyError = {
    code: 'KIRORA_API_ERROR',
    message: 'Kirora: token expired',
    userInfo: { status: 401, code: 'UNAUTHORIZED', retryAfterMs: null }
  };
  const refused = await make().identify('t').catch((e) => e);
  expect(refused).toBeInstanceOf(KiroraApiError);
  expect(refused).toMatchObject({ status: 401, code: 'UNAUTHORIZED', retryAfterMs: undefined, message: 'Kirora: token expired' });

  native.identifyError = { code: 'KIRORA_ERROR', message: 'Kirora: identify() needs a token or fetchUserToken' };
  const setup = await make().identify().catch((e) => e);
  expect(setup).toBeInstanceOf(KiroraError);
  expect(setup).not.toBeInstanceOf(KiroraApiError);
  expect(setup.message).toBe('Kirora: identify() needs a token or fetchUserToken');
});

test('beforeSend redacts or drops app events before they reach the native SDK', async () => {
  const k = make({
    beforeSend: (e) => (e.name === 'Secret' ? null : { ...e, properties: { ...e.properties, email: undefined } })
  });
  k.track('Signed Up', { plan: 'pro', email: 'a@b.c' });
  k.track('Secret', { x: 1 });
  k.trackScreenView('Home');
  await k.flush();
  expect(native.calls.filter((c) => c[0] === 'track')).toEqual([
    ['track', 'Signed Up', '{"plan":"pro"}'],
    ['track', 'Screen Viewed', '{"name":"Home"}']
  ]);
});

test('getPushStatus and setPushEnabled go to the native SDK', async () => {
  const k = make();
  expect(await k.getPushStatus()).toBe('enabled');
  await k.setPushEnabled(false);
  expect(native.calls).toContainEqual(['setPushEnabled', false]);
});

test('logout never rejects, and a destroyed client sends nothing more', async () => {
  const k = make({ logLevel: 'none' });
  (native as any).logout = async () => {
    throw new Error('native failure');
  };
  await expect(k.logout()).resolves.toBeUndefined();
  k.destroy();
  k.track('After Destroy');
  await tick();
  expect(native.calls.some((c) => c[1] === 'After Destroy')).toBe(false);
});

test('fetchUserToken stays in JavaScript: the native SDK asks, the answer goes back', async () => {
  let fail = false;
  make({ fetchUserToken: async () => (fail ? Promise.reject(new Error('server down')) : 'fresh.token') });
  await tick();
  const ask = native.listeners.get('KiroraTokenRequest')!;
  ask({ requestId: 'r1' });
  await tick(10);
  fail = true;
  ask({ requestId: 'r2' });
  await tick(10);
  expect(native.calls).toContainEqual(['resolveToken', 'r1', 'fresh.token', null]);
  expect(native.calls).toContainEqual(['resolveToken', 'r2', null, 'server down']);
});

test('the push look and the foreground hook are passed to the native SDK', async () => {
  const k = make({
    push: {
      smallIcon: 'ic_notification',
      accentColor: '#FF5500',
      defaultChannelId: 'promos',
      defaultChannelName: 'Promotions',
      onForegroundNotification: (d) => d.plan !== 'muted'
    }
  });
  await k.getState();
  expect(native.configured).toMatchObject({
    push: true,
    smallIcon: 'ic_notification',
    accentColor: '#FF5500',
    defaultChannelId: 'promos',
    defaultChannelName: 'Promotions',
    hasForegroundHandler: true
  });
});

test('the foreground hook answers each push the native SDK asks about, and a failing hook shows the push', async () => {
  let throwIt = false;
  make({
    push: {
      onForegroundNotification: async (d) => {
        if (throwIt) throw new Error('hook broke');
        return d.plan !== 'muted';
      }
    }
  });
  await tick();
  const ask = native.listeners.get('KiroraForegroundNotification')!;
  ask({ requestId: 'a', data: { plan: 'pro' } });
  ask({ requestId: 'b', data: { plan: 'muted' } });
  await tick(10);
  throwIt = true;
  ask({ requestId: 'c', data: { plan: 'pro' } });
  await tick(10);
  expect(native.calls.filter((c) => c[0] === 'resolveAnswer')).toEqual([
    ['resolveAnswer', 'a', true],
    ['resolveAnswer', 'b', false],
    ['resolveAnswer', 'c', true]
  ]);
});

test('notification listeners start the native events, hear taps and pushes, and stop them again', async () => {
  const k = make();
  const taps: unknown[] = [];
  const received: unknown[] = [];
  const offClick = k.onNotificationClicked((d) => taps.push(d));
  const offReceived = k.onNotificationReceived((d) => received.push(d));
  await tick();
  native.listeners.get('KiroraNotificationClicked')!({ plan: 'pro' });
  native.listeners.get('KiroraNotificationReceived')!({ kirora: 'true' });
  expect(taps).toEqual([{ plan: 'pro' }]);
  expect(received).toEqual([{ kirora: 'true' }]);

  offClick();
  offReceived();
  await tick();
  const events = native.calls.filter((c) => c[0] === 'setNotificationEvents');
  expect(events[events.length - 1]).toEqual(['setNotificationEvents', false, false]);
  expect(events).toContainEqual(['setNotificationEvents', true, true]);
});

test('handleDeepLink answers each link the native SDK asks about; a throwing one leaves it to the SDK', async () => {
  jest.spyOn(console, 'error').mockImplementation(() => undefined);
  make({
    handleDeepLink: (url) => {
      if (url.includes('broken')) throw new Error('nope');
      return url.startsWith('myapp://');
    }
  });
  expect(native.configured?.hasDeepLinkHandler).toBe(true);
  const ask = native.listeners.get('KiroraDeepLink')!;
  ask({ requestId: 'a', url: 'myapp://orders/1' });
  ask({ requestId: 'b', url: 'https://example.com' });
  ask({ requestId: 'c', url: 'myapp://broken' });
  await tick();
  expect(native.calls.filter((c) => c[0] === 'resolveAnswer')).toEqual([
    ['resolveAnswer', 'a', true],
    ['resolveAnswer', 'b', false],
    ['resolveAnswer', 'c', false]
  ]);
});

test('a link request JavaScript answers after the native SDK stopped waiting is not routed', async () => {
  jest.spyOn(console, 'error').mockImplementation(() => undefined);
  const routed: string[] = [];
  make({ handleDeepLink: (url) => (routed.push(url), true) });
  const ask = native.listeners.get('KiroraDeepLink')!;
  ask({ requestId: 'late', url: 'myapp://late', expiresAt: Date.now() - 1 });
  ask({ requestId: 'live', url: 'myapp://live', expiresAt: Date.now() + 1500 });
  await tick();
  expect(routed).toEqual(['myapp://live']);
  expect(native.calls.filter((c) => c[0] === 'resolveAnswer')).toEqual([['resolveAnswer', 'live', true]]);
});

test('a choice or event sent just before the client is replaced still reaches the native SDK, in order', async () => {
  const first = make();
  await first.getState();
  first.setTrackingConsent(true);
  first.track('Last', {});
  make();
  await tick();
  expect(native.calls.filter((c) => c[0] === 'setTrackingConsent' || c[0] === 'track')).toEqual([
    ['setTrackingConsent', true],
    ['track', 'Last', '{}']
  ]);
});

test('an own __proto__ member is kept as data, at any depth', async () => {
  const k = make();
  k.track('Proto', JSON.parse('{"__proto__":{"tier":"gold"},"order_id":"ORD-1042","nested":{"__proto__":1}}'));
  await tick();
  const sent = native.calls.find((c) => c[0] === 'track')!;
  expect(sent[2]).toBe('{"__proto__":{"tier":"gold"},"order_id":"ORD-1042","nested":{"__proto__":1}}');
});

test("a getter that throws in the app's object drops that event, never throws, and the next one goes", async () => {
  const logged = jest.spyOn(console, 'error').mockImplementation(() => undefined);
  let thenable = false;
  const k = make({
    beforeSend: (e) =>
      thenable
        ? (Object.defineProperty({ ...e }, 'then', { get() { throw new Error('secret'); } }) as any)
        : e
  });
  await k.getState();
  const tagged = Object.defineProperty({}, Symbol.toStringTag, { get() { throw new Error('secret'); } });
  expect(() => k.track('Tagged', tagged as any)).not.toThrow();
  thenable = true;
  expect(() => k.track('Thenable', {})).not.toThrow();
  thenable = false;
  k.track('Fine', { a: 1 });
  await tick();
  expect(native.calls.filter((c) => c[0] === 'track')).toEqual([['track', 'Fine', '{"a":1}']]);
  expect(JSON.stringify(logged.mock.calls)).not.toContain('secret');
});

test('replacing the client never stops the native module the new one set up', async () => {
  make();
  const second = make();
  await tick();
  expect(native.calls.filter((c) => c[0] === 'destroy')).toEqual([]);
  second.destroy();
  await tick();
  expect(native.calls.filter((c) => c[0] === 'destroy')).toEqual([['destroy']]);
});

test('setPushConsent resolves once recorded and rejects, mapped, when Kirora did not record it', async () => {
  const k = make();
  await expect(k.setPushConsent(true)).resolves.toBeUndefined();
  native.setPushConsent = async () => {
    throw Object.assign(new Error('Kirora: rate limited'), {
      code: 'KIRORA_API_ERROR',
      userInfo: { status: 429, code: 'RATE_LIMITED', retryAfterMs: 30000 }
    });
  };
  await expect(k.setPushConsent(true)).rejects.toMatchObject({ status: 429, code: 'RATE_LIMITED', retryAfterMs: 30000, retryable: true });
  native.setPushConsent = async () => {
    throw Object.assign(new Error('The Internet connection appears to be offline.'), { code: 'KIRORA_ERROR' });
  };
  const offline = await k.setPushConsent(false).catch((e) => e);
  expect(offline).toBeInstanceOf(KiroraError);
  expect(offline).not.toBeInstanceOf(KiroraApiError);
});

test("a replaced client's unsubscribe never turns off the new client's notification events", async () => {
  const first = make();
  const offFirst = first.onNotificationClicked(() => undefined);
  const second = make();
  second.onNotificationClicked(() => undefined);
  await tick();
  native.calls.length = 0;
  offFirst();
  expect(first.onNotificationClicked(() => undefined)).toBeInstanceOf(Function);
  await tick();
  expect(native.calls.filter((c) => c[0] === 'setNotificationEvents')).toEqual([]);
});

test('getState, getPushStatus and requestPushPermission never reject, as on Flutter; a destroyed client answers quietly', async () => {
  const notConfigured = () => Promise.reject(Object.assign(new Error('Kirora was not set up'), { code: 'NOT_CONFIGURED' }));
  native.getState = notConfigured as any;
  (native as any).getPushStatus = notConfigured;
  native.requestPushPermission = notConfigured as any;
  const k = make({ logLevel: 'none' });
  await expect(k.getState()).resolves.toEqual(EMPTY_STATE);
  await expect(k.getPushStatus()).resolves.toBe('unsupported');
  await expect(k.requestPushPermission()).resolves.toBe('unsupported');
  k.destroy();
  await expect(k.getState()).resolves.toMatchObject({ isInitialized: false });
  await expect(k.getPushStatus()).resolves.toBe('unsupported');
  await expect(k.requestPushPermission()).resolves.toBe('unsupported');
});

test('a missing screen name, push token or installation ID never reaches the native module', async () => {
  jest.spyOn(console, 'error').mockImplementation(() => undefined);
  const k = make();
  k.trackScreenView(undefined as any);
  k.trackScreenView('');
  k.onNewPushToken(null as any);
  k.onPushRegistered('');
  await k.flush();
  expect(
    native.calls.filter((c) => ['trackScreenView', 'onNewPushToken', 'onPushRegistered'].includes(c[0] as string))
  ).toEqual([]);
});

test('an empty fetchUserToken answer goes back empty, for the native SDK to fail the request as such', async () => {
  make({ fetchUserToken: async () => null });
  await tick();
  native.listeners.get('KiroraTokenRequest')!({ requestId: 'r' });
  await tick();
  expect(native.calls.filter((c) => c[0] === 'resolveToken')).toEqual([['resolveToken', 'r', null, null]]);
});

test('an async handleDeepLink is awaited: resolving true means handled', async () => {
  jest.spyOn(console, 'error').mockImplementation(() => undefined);
  make({
    handleDeepLink: async (url) => {
      await tick(1);
      if (url.includes('broken')) throw new Error('nope');
      return url.startsWith('myapp://');
    }
  });
  const ask = native.listeners.get('KiroraDeepLink')!;
  ask({ requestId: 'a', url: 'myapp://orders/1', expiresAt: Date.now() + 1500 });
  ask({ requestId: 'b', url: 'https://example.com', expiresAt: Date.now() + 1500 });
  ask({ requestId: 'c', url: 'myapp://broken', expiresAt: Date.now() + 1500 });
  await tick(20);
  expect(native.calls.filter((c) => c[0] === 'resolveAnswer')).toEqual([
    ['resolveAnswer', 'a', true],
    ['resolveAnswer', 'b', false],
    ['resolveAnswer', 'c', false]
  ]);
});

test('beforeSend never sees an event while tracking consent is refused', async () => {
  const { k, seen } = makeSeeing();
  k.track('Before Setup', {});
  await k.getState();
  k.setTrackingConsent(false);
  k.track('Refused', { email: 'a@b.c' });
  k.trackScreenView('Hidden');
  k.setTrackingConsent(true);
  k.track('Allowed', {});
  await tick();
  expect(seen).toEqual(['Before Setup', 'Allowed']);
  expect(tracked()).toEqual(['Before Setup', 'Allowed']);
});

test("with a remembered refusal, events tracked before setup answers never reach beforeSend", async () => {
  native.trackingConsent = false;
  const { k, seen } = makeSeeing();
  k.track('Early', { email: 'a@b.c' });
  await k.getState();
  k.track('Later', {});
  await tick();
  expect(seen).toEqual([]);
  expect(tracked()).toEqual([]);
});

test('calls made while events wait for setup reach the native SDK after them, in call order', async () => {
  const k = make({ beforeSend: (e) => e });
  k.track('Purchase', {});
  const flushed = k.flush();
  const loggedOut = k.logout();
  const identified = k.identify('tok');
  k.onNewPushToken('t1');
  await Promise.all([flushed, loggedOut, identified]);
  expect(native.calls.map((c) => c[0])).toEqual(['track', 'flush', 'logout', 'identify', 'onNewPushToken']);
});

test('an event waiting for setup stays with the user who was signed in when it was tracked', async () => {
  const k = make({ beforeSend: (e) => e });
  const a = k.identify('A');
  k.track('Purchase', {});
  const b = k.identify('B');
  const out = k.logout();
  await Promise.all([a, b, out]);
  expect(native.calls.filter((c) => c[0] !== 'getState')).toEqual([
    ['identify', 'A'],
    ['track', 'Purchase', '{}'],
    ['identify', 'B'],
    ['logout']
  ]);
});

test('destroy before setup answers still hands waiting events to the native SDK, then stops it', async () => {
  const k = make({ beforeSend: (e) => e });
  k.track('Last', {});
  k.destroy();
  await tick();
  expect(native.calls.map((c) => c[0])).toEqual(['track', 'setNotificationEvents', 'destroy']);
});

test('a client replaced before setup answers hands its waiting events to the native SDK, never stopping the new client', async () => {
  const first = make({ beforeSend: (e) => e });
  first.track('Before Replace', {});
  make();
  await tick();
  expect(native.calls.filter((c) => c[0] === 'track' || c[0] === 'destroy')).toEqual([['track', 'Before Replace', '{}']]);
});

test('destroy, then a new client, before setup answers: the event and the stop come before the new setup', async () => {
  const first = make({ beforeSend: (e) => e });
  first.track('Waiting', {});
  first.destroy();
  const configure = native.configure.bind(native);
  native.configure = async (o) => (native.calls.push(['configure']), configure(o));
  make();
  await tick();
  expect(native.calls.map((c) => c[0]).filter((n) => n !== 'setNotificationEvents')).toEqual(['track', 'destroy', 'configure']);
});

test('a logout made after a waiting event still goes when the client is replaced, after the event', async () => {
  const first = make({ beforeSend: (e) => e });
  first.track('Purchase', {});
  void first.logout();
  make();
  await tick();
  expect(native.calls.filter((c) => c[0] === 'track' || c[0] === 'logout').map((c) => c[0])).toEqual(['track', 'logout']);
});

test('a refusal on the replacing client still keeps the old client\'s waiting events from beforeSend', async () => {
  const { k: first, seen } = makeSeeing();
  first.track('Purchase', { email: 'a@b.c' });
  const second = make();
  second.setTrackingConsent(false);
  await tick();
  expect(seen).toEqual([]);
  expect(tracked()).toEqual([]);
});

test('a refusal made while an event waits for setup keeps that event from beforeSend', async () => {
  const { k, seen } = makeSeeing();
  k.track('Purchase', { email: 'a@b.c' });
  k.setTrackingConsent(false);
  await k.getState();
  await tick();
  expect(seen).toEqual([]);
  expect(tracked()).toEqual([]);
});

test('events keep their order when consent is given while earlier ones wait for setup', async () => {
  const k = make({ beforeSend: (e) => e });
  k.track('A', {});
  k.setTrackingConsent(true);
  k.track('B', {});
  await k.getState();
  k.track('C', {});
  await tick();
  expect(tracked()).toEqual(['A', 'B', 'C']);
});

test('with no consent answer at all, beforeSend sees nothing until consent is given', async () => {
  jest.spyOn(console, 'error').mockImplementation(() => undefined);
  native.trackingConsent = undefined;
  const { k, seen } = makeSeeing();
  k.track('Early', {});
  await k.getState();
  k.setTrackingConsent(true);
  k.track('Granted', {});
  await tick();
  expect(seen).toEqual(['Granted']);
});

test('push permission and status answer unsupported after a failed setup, never reject', async () => {
  jest.spyOn(console, 'error').mockImplementation(() => undefined);
  native.configure = async () => {
    throw Object.assign(new Error('Kirora: apiUrl must use https'), { code: 'CONFIGURE_ERROR' });
  };
  const k = make();
  await expect(k.requestPushPermission()).resolves.toBe('unsupported');
  await expect(k.getPushStatus()).resolves.toBe('unsupported');
});

test("beforeSend's answer that isn't plain JSON is dropped, saying why", async () => {
  const logged = jest.spyOn(console, 'error').mockImplementation(() => undefined);
  const k = make({ beforeSend: (e) => ({ ...e, properties: Object.create({ tier: 'gold' }) }) });
  await k.getState();
  k.track('Proto', {});
  await tick();
  expect(native.calls.filter((c) => c[0] === 'track')).toEqual([]);
  expect(String(logged.mock.calls[0][0])).toMatch(/Proto not tracked: beforeSend's answer holds an object .*copy and delete/);
});

test('the old Android channel option names are reported, not used', async () => {
  const logged = jest.spyOn(console, 'error').mockImplementation(() => undefined);
  make({ push: { channelId: 'promos', channelName: 'Promotions' } as any });
  await tick();
  expect(native.configured?.defaultChannelId).toBeNull();
  expect(logged.mock.calls.map((c) => c[0])).toEqual([
    '[Kirora] push.channelId is ignored: it is now push.defaultChannelId',
    '[Kirora] push.channelName is ignored: it is now push.defaultChannelName'
  ]);
});

test('a failed native setup is what identify rejects with', async () => {
  jest.spyOn(console, 'error').mockImplementation(() => undefined);
  native.configure = async () => {
    throw Object.assign(new Error('Kirora: apiUrl must use https'), { code: 'CONFIGURE_ERROR' });
  };
  const failure = await make().identify('t').catch((e) => e);
  expect(failure).toBeInstanceOf(KiroraError);
  expect(failure.message).toBe('Kirora: apiUrl must use https');
});

test('a second instance stops listening for the first', async () => {
  make({ fetchUserToken: async () => 'a' });
  make({ fetchUserToken: async () => 'b' });
  await tick();
  native.listeners.get('KiroraTokenRequest')!({ requestId: 'x' });
  await tick(10);
  expect(native.calls.filter((c) => c[0] === 'resolveToken')).toEqual([['resolveToken', 'x', 'b', null]]);
});

test('without the native module every call is a safe no-op, and one error says why', async () => {
  const logged = jest.spyOn(console, 'error').mockImplementation(() => undefined);
  const k = new Kirora({ clientKey: 'kirora_pk_p', fetchUserToken: async () => 't' }, { native: null });
  expect(k.isAvailable).toBe(false);
  expect(logged).toHaveBeenCalledTimes(1);
  expect(String(logged.mock.calls[0][0])).toMatch(/development build/);
  await expect(k.identify()).resolves.toBeUndefined();
  k.track('Event', { a: 1 });
  k.trackScreenView('Home');
  await expect(k.flush()).resolves.toBeUndefined();
  await expect(k.logout()).resolves.toBeUndefined();
  await expect(k.requestPushPermission()).resolves.toBe('unsupported');
  await expect(k.getPushStatus()).resolves.toBe('unsupported');
  expect((await k.getState()).isInitialized).toBe(false);
  k.onNotificationClicked(() => undefined)();
  k.destroy();
  expect(logged).toHaveBeenCalledTimes(1);

  new Kirora({ clientKey: 'kirora_pk_p', logLevel: 'none' }, { native: null });
  expect(logged).toHaveBeenCalledTimes(1);
});

describe('finding the native module in the runtime', () => {
  const load = (rn: object) => {
    jest.resetModules();
    let Fresh!: typeof Kirora;
    jest.isolateModules(() => {
      jest.doMock('react-native', () => rn, { virtual: true });
      Fresh = require('../Kirora').Kirora;
    });
    return Fresh;
  };

  class Emitter {
    addListener() {
      return { remove() {} };
    }
  }

  test('iOS and Android use the native module when it is linked', () => {
    for (const OS of ['ios', 'android']) {
      const Fresh = load({ Platform: { OS }, NativeModules: { KiroraSdk: native }, NativeEventEmitter: Emitter });
      expect(new Fresh({ clientKey: 'kirora_pk_a' }).isAvailable).toBe(true);
    }
  });

  test('without the module linked (Expo Go), on either platform, it is unavailable', () => {
    for (const OS of ['ios', 'android']) {
      const Fresh = load({ Platform: { OS }, NativeModules: {} });
      expect(new Fresh({ clientKey: '', logLevel: 'none' }).isAvailable).toBe(false);
    }
  });

  test('on the web it is unavailable, and says to use the web SDK rather than a development build', () => {
    const logged = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    const Fresh = load({ Platform: { OS: 'web' }, NativeModules: { KiroraSdk: native }, NativeEventEmitter: Emitter });
    expect(new Fresh({ clientKey: '' }).isAvailable).toBe(false);
    expect(logged).toHaveBeenCalledTimes(1);
    expect(logged.mock.calls[0][0]).toContain('@kirora/web');
    expect(logged.mock.calls[0][0]).not.toContain('Expo Go');
  });

  test('on another platform (macOS, Windows) it says Android and iOS only, without the web advice', () => {
    const logged = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    const Fresh = load({ Platform: { OS: 'macos' }, NativeModules: {} });
    expect(new Fresh({ clientKey: '' }).isAvailable).toBe(false);
    expect(logged.mock.calls[0][0]).toContain('Android and iOS only');
    expect(logged.mock.calls[0][0]).not.toContain('@kirora/web');
  });
});

test('onAuthenticationFailed hears why the token failed in the background; a throwing one breaks nothing', async () => {
  jest.spyOn(console, 'error').mockImplementation(() => undefined);
  const reasons: string[] = [];
  make({
    onAuthenticationFailed: (reason) => {
      reasons.push(reason);
      if (reason === 'refused') throw new Error('app bug');
    }
  });
  expect(native.configured?.hasAuthenticationFailedHandler).toBe(true);
  const fail = native.listeners.get('KiroraAuthenticationFailed')!;
  fail({ reason: 'fetch_failed' });
  expect(() => fail({ reason: 'refused' })).not.toThrow();
  expect(reasons).toEqual(['fetch_failed', 'refused']);
});

describe('the bridge boundary', () => {
  /**
   * Runs `body` and lets what it started settle. Jest fails the test on any unhandled rejection
   * while it runs (a listener on `process` doesn't see them inside Jest's sandbox), so reaching
   * the end means none reached the app.
   */
  const settle = async (body: () => Promise<void>) => {
    await body();
    await tick(20);
  };

  test('a native method that throws (an older binary) never throws at the app or leaves a rejection', async () => {
    const logged = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    const k = make();
    const broken = () => {
      throw new TypeError('native.track is not a function');
    };
    native.track = broken;
    native.trackScreenView = broken;
    native.onNewPushToken = broken;
    native.onPushRegistered = broken;
    native.setNotificationEvents = broken;
    native.setTrackingConsent = broken;
    native.destroy = broken;
    native.flush = broken as never;
    native.identify = broken as never;
    await settle(async () => {
      expect(() => k.track('Order Completed', { total: 1 })).not.toThrow();
      expect(() => k.trackScreenView('Home')).not.toThrow();
      expect(() => k.onNewPushToken('fcm')).not.toThrow();
      expect(() => k.onPushRegistered('fid')).not.toThrow();
      expect(() => k.setTrackingConsent(true)).not.toThrow();
      expect(() => k.onNotificationClicked(() => undefined)).not.toThrow();
      await expect(k.flush()).resolves.toBeUndefined();
      // Mapped to the SDK's own error, as any native failure is.
      await expect(k.identify('t')).rejects.toBeInstanceOf(KiroraError);
      expect(() => k.destroy()).not.toThrow();
    });
    expect(logged.mock.calls.map((c) => c[0])).toEqual(
      expect.arrayContaining(['[Kirora] Tracking Order Completed failed', '[Kirora] setTrackingConsent failed'])
    );
  });

  test('an event held for beforeSend whose native call throws is logged, not left as a rejection', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => undefined);
    native.trackingConsent = undefined;
    const { k } = makeSeeing();
    native.track = () => {
      throw new Error('bridge refused');
    };
    await settle(async () => {
      k.setTrackingConsent(true);
      k.track('Held');
    });
  });

  test('a consent that is not a boolean changes nothing (iOS would read it as a refusal)', async () => {
    const logged = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    const k = make();
    k.setTrackingConsent(undefined as unknown as boolean);
    k.setTrackingConsent('yes' as unknown as boolean);
    await expect(k.setPushConsent(1 as unknown as boolean)).rejects.toBeInstanceOf(KiroraError);
    await expect(k.setPushEnabled(null as unknown as boolean)).resolves.toBeUndefined();
    await tick();
    expect(native.calls.filter((c) => ['setTrackingConsent', 'setPushConsent', 'setPushEnabled'].includes(c[0]))).toEqual([]);
    expect(logged).toHaveBeenCalledWith('[Kirora] setTrackingConsent() takes true or false: the choice is unchanged', '');
    // A refusal that never happened doesn't hold back events either.
    k.track('After');
    await tick();
    expect(tracked()).toEqual(['After']);
  });

  test('identify() with a token that is not a string rejects without reaching the bridge', async () => {
    const k = make();
    await expect(k.identify(42 as unknown as string)).rejects.toThrow('identify() takes a token string');
    await expect(k.identify(null as unknown as string)).resolves.toBeUndefined();
    expect(native.calls.filter((c) => c[0] === 'identify')).toEqual([['identify', null]]);
  });

  test('fetchUserToken answering something other than a string fails the request, saying why', async () => {
    const logged = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    make({ fetchUserToken: async () => ({ token: 'abc' }) as unknown as string });
    native.listeners.get('KiroraTokenRequest')!({ requestId: 'r1' });
    await tick();
    expect(native.calls).toContainEqual(['resolveToken', 'r1', null, 'fetchUserToken must answer a string']);
    expect(logged).toHaveBeenCalledWith('[Kirora] fetchUserToken must answer a string, not object', '');
  });

  test('no token from fetchUserToken still fails the request as no token', async () => {
    make({ fetchUserToken: async () => null });
    native.listeners.get('KiroraTokenRequest')!({ requestId: 'r3' });
    await tick();
    expect(native.calls).toContainEqual(['resolveToken', 'r3', null, null]);
  });

  test('a token answer the bridge refuses is logged, not left as a rejection', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => undefined);
    make({ fetchUserToken: async () => 'tok' });
    native.resolveToken = () => {
      throw new Error('module went away');
    };
    await settle(async () => {
      native.listeners.get('KiroraTokenRequest')!({ requestId: 'r2' });
    });
  });

  test('a native call that throws while setup is still running rejects only through its own promise', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => undefined);
    let finishSetup!: (answer: { trackingConsent: boolean }) => void;
    native.configure = async (o) => {
      native.configured = o;
      return new Promise((resolve) => (finishSetup = resolve));
    };
    const k = make();
    native.identify = () => {
      throw new Error('bridge failure');
    };
    native.flush = () => {
      throw new Error('bridge failure');
    };
    await settle(async () => {
      const identified = k.identify('t');
      const flushed = k.flush();
      // Setup still running: without the fix, both sends were unhandled rejections by now.
      await tick(20);
      finishSetup({ trackingConsent: true });
      await expect(identified).rejects.toBeInstanceOf(KiroraError);
      await expect(flushed).resolves.toBeUndefined();
    });
  });

  test('destroy() stops the native client even when turning notification events off fails', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => undefined);
    const k = make();
    native.setNotificationEvents = () => {
      throw new Error('missing in this binary');
    };
    await settle(async () => k.destroy());
    expect(native.calls).toContainEqual(['destroy']);
  });

  test('a refusal the native SDK failed to take still holds JavaScript\'s events back', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => undefined);
    const { k, seen } = makeSeeing();
    native.setTrackingConsent = () => {
      throw new Error('bridge refused');
    };
    k.setTrackingConsent(false);
    k.track('Not Tracked');
    await tick();
    expect(seen).toEqual([]);
    expect(tracked()).toEqual([]);
  });

  test('without beforeSend too, a refusal the native SDK failed to take stops events and screen views', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => undefined);
    const k = make();
    await k.getState();
    native.setTrackingConsent = () => {
      throw new Error('bridge refused');
    };
    k.setTrackingConsent(false);
    k.track('Not Tracked');
    k.trackScreenView('Cart');
    await tick();
    expect(native.calls.filter((c) => c[0] === 'track' || c[0] === 'trackScreenView')).toEqual([]);
  });

  test('a grant the native SDK failed to take leaves JavaScript as it was', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => undefined);
    const { k, seen } = makeSeeing();
    k.setTrackingConsent(false);
    native.setTrackingConsent = () => {
      throw new Error('bridge refused');
    };
    k.setTrackingConsent(true);
    k.track('Still Held');
    await tick();
    expect(seen).toEqual([]);
  });

  test('a native call that answers a rejected promise is logged, not left unhandled', () =>
    settle(() => {
      const errors = jest.spyOn(console, 'error').mockImplementation(() => undefined);
      native.track = () => Promise.reject(new Error('turbo refused'));
      const k = make();
      return tick().then(() => {
        k.track('Async Failure');
        return tick().then(() =>
          expect(errors).toHaveBeenCalledWith('[Kirora] Tracking Async Failure failed', expect.any(Error)));
      });
    }));

  test('a bad setPushEnabled argument is logged without claiming push was turned on', async () => {
    const errors = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    const k = make();
    await k.setPushEnabled('false' as unknown as boolean);
    expect(errors.mock.calls[0][0]).toBe('[Kirora] setPushEnabled failed');
  });

  test('a destroyed client does nothing, whatever it is given', async () => {
    const k = make();
    k.destroy();
    await expect(k.identify(42 as unknown as string)).resolves.toBeUndefined();
    await expect(k.setPushConsent('yes' as unknown as boolean)).resolves.toBeUndefined();
    await expect(k.setPushEnabled(null as unknown as boolean)).resolves.toBeUndefined();
  });
});
