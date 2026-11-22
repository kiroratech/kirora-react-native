import { EMPTY_STATE, type KiroraBackend, type KiroraState } from './backend';
import { KiroraApiError, KiroraError, UserTokenError } from './errors';
import { isPlainObject, jsonSnapshot, NotJsonError } from './json';
import type { AuthenticationFailureReason, BeforeSendEvent, KiroraOptions, NotificationData, PushPermission, PushStatus } from './types';
import { SDK_VERSION } from './version';

/** The methods of the `KiroraSdk` native module: `android/src/main/java/io/kirora/reactnative`, `ios/`. */
export interface NativeKiroraModule {
  /** Answers whether tracking is allowed now: a remembered choice, or the default. */
  configure(options: NativeOptions): Promise<{ trackingConsent?: boolean } | null | void>;
  identify(token: string | null): Promise<void>;
  logout(): Promise<void>;
  track(name: string, propertiesJson: string): void;
  trackScreenView(name: string): void;
  setTrackingConsent(granted: boolean): void;
  /** Resolves once Kirora recorded it; rejects like `identify`. */
  setPushConsent(granted: boolean): Promise<void>;
  requestPushPermission(): Promise<PushPermission>;
  flush(): Promise<void>;
  /** Null when there is no client, or its state can't be read. */
  getState(): Promise<KiroraState | null>;
  onNewPushToken(token: string): void;
  getPushStatus(): Promise<PushStatus>;
  setPushEnabled(enabled: boolean): Promise<void>;
  destroy(): void;
  /** Answers a `KiroraTokenRequest` event: a token, or an error message when `fetchUserToken` failed. */
  resolveToken(requestId: string, token: string | null, error: string | null): void;
  /**
   * Answers a `KiroraForegroundNotification` event (show the push, or hold it back) or a
   * `KiroraDeepLink` event (whether the app opened the link itself).
   */
  resolveAnswer(requestId: string, answer: boolean): void;
  /** Starts (or stops) `KiroraNotificationClicked` / `KiroraNotificationReceived` events; taps that arrived earlier follow at once. */
  setNotificationEvents(clicked: boolean, received: boolean): void;
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export interface NativeOptions {
  clientKey: string;
  apiUrl: string;
  push: boolean;
  pushAppId: string | null;
  requireTrackingConsent: boolean;
  trackSessions: boolean;
  trackAppLifecycle: boolean;
  logLevel: string;
  hasTokenProvider: boolean;
  hasAuthenticationFailedHandler: boolean;
  smallIcon: string | null;
  accentColor: string | null;
  defaultChannelId: string | null;
  defaultChannelName: string | null;
  hasForegroundHandler: boolean;
  hasDeepLinkHandler: boolean;
  /** This package's version, sent as `Kirora-SDK: kirora-react-native/<version>`. */
  sdkVersion: string;
}

export interface NativeEventEmitterLike {
  addListener(eventName: string, listener: (event: any) => void): { remove(): void };
}

const TOKEN_REQUEST_EVENT = 'KiroraTokenRequest';
const FOREGROUND_EVENT = 'KiroraForegroundNotification';
const CLICKED_EVENT = 'KiroraNotificationClicked';
const RECEIVED_EVENT = 'KiroraNotificationReceived';
const DEEP_LINK_EVENT = 'KiroraDeepLink';
const AUTHENTICATION_FAILED_EVENT = 'KiroraAuthenticationFailed';

/** A question from the native SDK: `expiresAt` is when it stops waiting and acts on its own. */
interface NativeAsk {
  requestId: string;
  expiresAt?: number;
}

/** An app event as it crosses to the native SDK. */
type AppEvent = Omit<BeforeSendEvent, 'context'>;

/**
 * The calls into one native module, in the order they were made, shared by every client: they
 * drive one native SDK. A call goes at once while nothing waits. An app event waiting for setup's
 * consent answer (see `track`) holds the calls made after it, a newer client's `configure`
 * included, so it reaches the client and user that were current when it was tracked.
 */
class NativeQueue {
  /** Refusals of tracking, on any client: a waiting event goes only if none came since. */
  refusals = 0;
  private waiting = 0;
  /** Settles once the last queued call has been sent (not answered). */
  private tail: Promise<void> = Promise.resolve();

  /**
   * `send` now when nothing waits and there is no `ready`; otherwise after what waits, then `ready`.
   * A `send` that throws (a native method missing from an older binary, an argument the bridge
   * refuses) rejects the answer rather than throwing at the caller.
   */
  run<T>(send: () => T | Promise<T>, ready?: Promise<unknown>): Promise<T> {
    if (this.waiting === 0 && !ready) {
      try {
        return Promise.resolve(send());
      } catch (e) {
        return Promise.reject(e);
      }
    }
    this.waiting++;
    const previous = this.tail;
    let result!: Promise<T>;
    this.tail = new Promise<void>((sent) => {
      result = previous
        .then(() => Promise.resolve(ready).catch(() => undefined))
        .then(() => {
          this.waiting--;
          sent();
          return send();
        });
    });
    return result;
  }
}

const queues = new WeakMap<NativeKiroraModule, NativeQueue>();

/**
 * Hands every call to the native Kirora Android or iOS SDK. `fetchUserToken`, `handleDeepLink`
 * and `onForegroundNotification` stay in JavaScript: the native SDK asks with an event, and the
 * answer goes back with `resolveToken` or `resolveAnswer`. `beforeSend`
 * runs here, on the events the app tracks, before they cross. Notification opens are reported
 * by the native SDK on its own.
 *
 * Every call goes to the native module at once, not after `configure` settles (unless an event
 * waits, see `NativeQueue`): the module runs calls in order, after the `configure` this client
 * sent, so a call reaches the client that was current when it was made, even if a newer one
 * replaces it right after (a withdrawn consent).
 */
export class NativeBackend implements KiroraBackend {
  private readonly configured: Promise<void>;
  private readonly queue: NativeQueue;
  private readonly subscriptions: Array<{ remove(): void }> = [];
  private readonly clickListeners = new Set<(data: NotificationData) => void>();
  private readonly receivedListeners = new Set<(data: NotificationData) => void>();
  private destroyed = false;
  private inBeforeSend = false;
  /** Why the native setup failed, for `identify` to reject with. */
  private setupError?: KiroraError;
  private readonly beforeSend: KiroraOptions['beforeSend'];
  /**
   * Whether tracking is allowed: the app's latest choice, else the native SDK's answer at setup
   * (undefined until it answers, or when setup failed). `beforeSend` never sees an event
   * tracking doesn't allow.
   */
  private freshConsent?: boolean;
  private storedConsent?: boolean;
  private readonly logErrors: boolean;

  constructor(
    options: KiroraOptions & { clientKey: string },
    private readonly native: NativeKiroraModule,
    private readonly emitter: NativeEventEmitterLike
  ) {
    this.beforeSend = typeof options.beforeSend === 'function' ? options.beforeSend : undefined;
    this.logErrors = options.logLevel !== 'none';
    const queue = queues.get(native) ?? new NativeQueue();
    queues.set(native, queue);
    this.queue = queue;
    const fetchUserToken = options.fetchUserToken;
    if (fetchUserToken) {
      // An empty answer fails the request on the native side.
      this.subscriptions.push(emitter.addListener(TOKEN_REQUEST_EVENT, (event: NativeAsk) => {
        const answer = (token: string | null, error: string | null) =>
          this.now('Answering the token request', () => this.native.resolveToken(event.requestId, token, error));
        Promise.resolve()
          .then(fetchUserToken)
          .then(
            // Only a non-empty string crosses: the bridge refuses other types, and the native side
            // fails the request on null.
            (token) => answer(typeof token === 'string' && token !== '' ? token : null, null),
            (e) => answer(null, e instanceof Error ? e.message : String(e))
          );
      }));
    }
    const push = options.push;
    const pushOptions = typeof push === 'object' ? push : undefined;
    // Renamed before launch, with no alias (sdk-interface.md, 20 Nov): say so rather than
    // quietly fall back to the default channel.
    if (pushOptions) {
      if ('channelId' in pushOptions) this.error('push.channelId is ignored: it is now push.defaultChannelId');
      if ('channelName' in pushOptions) this.error('push.channelName is ignored: it is now push.defaultChannelName');
    }
    const foreground = pushOptions?.onForegroundNotification;
    if (foreground) {
      this.answer(FOREGROUND_EVENT, 'onForegroundNotification', true,
        async (event: NativeAsk & { data: NotificationData }) => (await foreground(event.data)) !== false);
    }
    const handleDeepLink = typeof options.handleDeepLink === 'function' ? options.handleDeepLink : undefined;
    if (handleDeepLink) {
      this.answer(DEEP_LINK_EVENT, 'handleDeepLink', false,
        async (event: NativeAsk & { url: string }) => (await handleDeepLink(event.url)) === true);
    }
    const onAuthenticationFailed =
      typeof options.onAuthenticationFailed === 'function' ? options.onAuthenticationFailed : undefined;
    if (onAuthenticationFailed) {
      this.subscriptions.push(
        emitter.addListener(AUTHENTICATION_FAILED_EVENT, (event: { reason: AuthenticationFailureReason }) =>
          this.safely('onAuthenticationFailed', () => onAuthenticationFailed(event.reason)))
      );
    }
    // The native module sends these only once `setNotificationEvents` turned them on.
    this.subscriptions.push(
      emitter.addListener(CLICKED_EVENT, (data: NotificationData) => this.deliver(this.clickListeners, data)),
      emitter.addListener(RECEIVED_EVENT, (data: NotificationData) => this.deliver(this.receivedListeners, data))
    );
    this.configured = queue
      .run(() => native.configure({
        clientKey: options.clientKey,
        apiUrl: options.apiUrl ?? 'https://api.kirora.io',
        push: !!push,
        pushAppId: pushOptions?.pushAppId ?? null,
        requireTrackingConsent: options.requireTrackingConsent ?? false,
        trackSessions: options.trackSessions ?? true,
        trackAppLifecycle: options.trackAppLifecycle ?? false,
        logLevel: options.logLevel ?? 'error',
        hasTokenProvider: !!fetchUserToken,
        hasAuthenticationFailedHandler: !!onAuthenticationFailed,
        smallIcon: pushOptions?.smallIcon ?? null,
        accentColor: pushOptions?.accentColor ?? null,
        defaultChannelId: pushOptions?.defaultChannelId ?? null,
        defaultChannelName: pushOptions?.defaultChannelName ?? null,
        hasForegroundHandler: !!foreground,
        hasDeepLinkHandler: !!handleDeepLink,
        sdkVersion: SDK_VERSION
      }))
      .then((answer) => {
        // Never assumed when missing: a refusal may be remembered on the device.
        const consent = answer?.trackingConsent;
        if (typeof consent === 'boolean') {
          this.storedConsent = consent;
        } else if (this.beforeSend) {
          this.error("Setup didn't say whether tracking is allowed: app events skip beforeSend and are dropped until setTrackingConsent()");
        }
      })
      .catch((e) => {
        this.setupError = errorFromNative(e);
        this.error('native setup failed', this.setupError);
      });
  }

  /**
   * Answers the native SDK's `event` with `handler`'s result: `fallback` when it throws or
   * rejects. Not asked once the native SDK stopped waiting: it has acted by then (opened the
   * link, shown the push), and the app's callback would act a second time.
   */
  private answer<E extends NativeAsk>(
    event: string,
    name: string,
    fallback: boolean,
    handler: (event: E) => boolean | Promise<boolean>
  ): void {
    this.subscriptions.push(
      this.emitter.addListener(event, (ask: E) => {
        const expired = () => typeof ask.expiresAt === 'number' && Date.now() > ask.expiresAt;
        if (expired()) {
          this.error(`${name} not asked: JavaScript got the request after the native SDK stopped waiting`);
          return;
        }
        Promise.resolve()
          .then(() => handler(ask))
          .then(
            (answer) => {
              if (expired()) {
                this.error(`${name} answered after the native SDK stopped waiting (about 1.5 s): it acted on its own`);
              }
              this.now(`Answering ${name}`, () => this.native.resolveAnswer(ask.requestId, answer));
            },
            (e) => {
              this.error(`${name} threw`, e);
              this.now(`Answering ${name}`, () => this.native.resolveAnswer(ask.requestId, fallback));
            }
          );
      })
    );
  }

  /**
   * Sends a call through the queue (at once, see the class), then answers what the native SDK
   * did, mapped to the SDK's errors; a failed setup rejects with why. `whenDestroyed` once this
   * client is destroyed.
   */
  private async call<T>(send: () => Promise<T>, whenDestroyed: T): Promise<T> {
    if (this.destroyed) return whenDestroyed;
    const pending = this.queue.run(send);
    await this.configured;
    if (this.setupError) {
      pending.catch(() => undefined);
      throw this.setupError;
    }
    try {
      return await pending;
    } catch (e) {
      throw errorFromNative(e);
    }
  }

  /**
   * Sends a call that answers nothing (`track`, an answer to the native SDK) through the queue, after
   * `ready` if given. What the native module throws is logged: it never reaches the app, as an
   * exception or an unhandled rejection.
   */
  private fire(what: string, send: () => unknown, ready?: Promise<unknown>): void {
    this.queue.run(send, ready).then(undefined, (e) => this.error(`${what} failed`, e));
  }

  /** A native call made at once, outside the queue, logged rather than thrown if the module throws. */
  private now(what: string, send: () => void): void {
    try {
      send();
    } catch (e) {
      this.error(`${what} failed`, e);
    }
  }

  /** `call`, logging and answering `fallback` instead of rejecting. */
  private quietly<T>(what: string, send: () => Promise<T>, fallback: T): Promise<T> {
    return this.call(send, fallback).catch((e) => {
      this.error(`${what} failed`, e);
      return fallback;
    });
  }

  /** Rejects with what the native SDK threw: `UserTokenError`, `KiroraApiError` or `KiroraError`. */
  identify(token?: string): Promise<void> {
    // Checked here: the bridge refuses another type (a crash on Android's old architecture).
    if (token !== undefined && token !== null && typeof token !== 'string') {
      return Promise.reject(new KiroraError('identify() takes a token string, or nothing to use fetchUserToken'));
    }
    return this.call(() => this.native.identify(token || null), undefined);
  }

  /** Never rejects. */
  logout(): Promise<void> {
    return this.quietly('logout', () => this.native.logout(), undefined);
  }

  track(name: string, properties?: Record<string, unknown>): void {
    if (this.destroyed) return;
    const event = this.snapshot(name, properties ?? {});
    if (!event) return;
    if (!this.beforeSend) {
      // The native SDK applies consent itself; no app code sees the event here.
      this.fire(`Tracking ${name}`, () => this.send(event));
      return;
    }
    const consent = this.freshConsent ?? this.storedConsent;
    if (consent === false) return;
    // beforeSend sees the event only once tracking is known to be allowed: at once, or, while
    // setup hasn't said (a remembered choice), once it has; never if tracking was refused since.
    // Calls made after it wait in the queue, so they keep their order. One from a client that is
    // destroyed meanwhile still goes: the native SDK keeps waiting events for the next client.
    const refusals = this.queue.refusals;
    this.fire(`Tracking ${name}`, () => {
      const allowed = consent ?? this.storedConsent;
      if (this.setupError) this.error(`${name} not tracked: native setup failed`);
      else if (allowed === undefined) this.error(`${name} not tracked: unknown whether tracking is allowed`);
      else if (allowed && this.queue.refusals === refusals) this.release(event);
    }, consent === undefined ? this.configured : undefined);
  }

  private release(event: AppEvent): void {
    const kept = this.applyBeforeSend(event);
    if (kept) this.send(kept);
  }

  private send(event: AppEvent): void {
    this.native.track(event.name, JSON.stringify(event.properties));
  }

  trackScreenView(name: string): void {
    if (this.destroyed) return;
    if (typeof name !== 'string' || name === '') {
      this.error('Screen view not tracked: it needs a name');
      return;
    }
    if (!this.beforeSend) {
      this.fire('Tracking a screen view', () => this.native.trackScreenView(name));
      return;
    }
    // Through beforeSend like any app event; the native SDK still names it `Screen Viewed`.
    this.track('Screen Viewed', { name });
  }

  /** Never queued: a refusal takes effect at once, and blocks the events still waiting. */
  setTrackingConsent(granted: boolean): void {
    if (this.destroyed) return;
    // Never guessed: iOS's old bridge reads a missing boolean as `false`, a silent refusal.
    if (typeof granted !== 'boolean') {
      this.error('setTrackingConsent() takes true or false: the choice is unchanged');
      return;
    }
    this.freshConsent = granted;
    if (!granted) this.queue.refusals++;
    this.now('setTrackingConsent', () => this.native.setTrackingConsent(granted));
  }

  /** Resolves once Kirora recorded the choice; rejects, as `identify` does, when it didn't. */
  setPushConsent(granted: boolean): Promise<void> {
    if (typeof granted !== 'boolean') {
      return Promise.reject(new KiroraError('setPushConsent() takes true or false: nothing was recorded'));
    }
    return this.call(() => this.native.setPushConsent(granted), undefined);
  }

  /** Never rejects: `unsupported` when the native SDK can't answer (a failed setup, say). */
  requestPushPermission(): Promise<PushPermission> {
    return this.quietly<PushPermission>('requestPushPermission', () => this.native.requestPushPermission(), 'unsupported');
  }

  /** Never rejects: `unsupported` when the native SDK can't answer (a failed setup, say). */
  getPushStatus(): Promise<PushStatus> {
    return this.quietly<PushStatus>('getPushStatus', () => this.native.getPushStatus(), 'unsupported');
  }

  /** Never rejects. */
  setPushEnabled(enabled: boolean): Promise<void> {
    if (typeof enabled !== 'boolean') {
      this.error('setPushEnabled() takes true or false: push is unchanged');
      return Promise.resolve();
    }
    return this.quietly(`Turning push ${enabled ? 'on' : 'off'}`, () => this.native.setPushEnabled(enabled), undefined);
  }

  /** Never rejects. */
  flush(): Promise<void> {
    return this.quietly('flush', () => this.native.flush(), undefined);
  }

  /** Never rejects: the empty state when it can't be read. */
  async getState(): Promise<KiroraState> {
    try {
      return { ...EMPTY_STATE, ...(await this.call(() => this.native.getState(), null)) };
    } catch (e) {
      this.error("Couldn't read the state", e);
      return { ...EMPTY_STATE };
    }
  }

  /**
   * Stops this client's listeners; the native SDK keeps what waits. `stopNative` when it is the
   * current client: a replaced one leaves the module to the client that set it up again. Queued
   * like any call, so events still waiting reach the native SDK first.
   */
  destroy(stopNative: boolean): void {
    if (this.destroyed) return;
    this.destroyed = true;
    this.subscriptions.forEach((s) => s.remove());
    if (stopNative) {
      this.fire('Stopping the native SDK', () => {
        this.native.setNotificationEvents(false, false);
        this.native.destroy();
      });
    }
  }

  /**
   * The event's properties copied as JSON now, as `track` was called. Undefined when it is
   * dropped. Only the failure's kind is logged, never the event. Getters of the app's objects
   * run only inside guards: one that throws drops the event.
   */
  private snapshot(name: string, properties: unknown): AppEvent | undefined {
    if (this.inBeforeSend) {
      this.error('Not tracked: called from beforeSend');
      return undefined;
    }
    if (typeof name !== 'string' || name === '' || !isPlainObject(properties)) {
      this.error('Not tracked: needs a name, and properties as an object');
      return undefined;
    }
    let snapshot: Record<string, unknown>;
    try {
      snapshot = jsonSnapshot(properties) as Record<string, unknown>;
    } catch (e) {
      this.error(`${name} not tracked: its properties hold ${e instanceof NotJsonError ? e.message : 'something JSON has no form for'}`);
      return undefined;
    }
    return { name, properties: snapshot };
  }

  /** The event as `beforeSend` leaves it; undefined when it drops it or answers wrongly. */
  private applyBeforeSend({ name, properties: snapshot }: AppEvent): AppEvent | undefined {
    let answer: unknown;
    this.inBeforeSend = true;
    try {
      answer = this.beforeSend!({ name, properties: snapshot, context: {} });
    } catch {
      this.error(`${name} not tracked: beforeSend threw`);
      return undefined;
    } finally {
      this.inBeforeSend = false;
    }
    if (answer === null) return undefined;
    try {
      if (typeof (answer as PromiseLike<unknown> | undefined)?.then === 'function') {
        Promise.resolve(answer).catch(() => undefined);
        this.error(`${name} not tracked: beforeSend must answer at once, not later`);
        return undefined;
      }
      const properties = isPlainObject(answer) ? (answer as Partial<BeforeSendEvent>).properties ?? {} : undefined;
      if (!isPlainObject(properties)) {
        this.error(`${name} not tracked: beforeSend must answer an event or null`);
        return undefined;
      }
      return { name, properties: jsonSnapshot(properties) as Record<string, unknown> };
    } catch (e) {
      // Only the failure's kind, never the event: a getter's own error could hold app values.
      this.error(e instanceof NotJsonError
        ? `${name} not tracked: beforeSend's answer holds ${e.message}${e.message.startsWith('an object') ? ' (copy and delete rather than `{ key, ...rest }`, which can turn a `__proto__` key into a prototype)' : ''}`
        : `${name} not tracked: reading beforeSend's answer threw`);
      return undefined;
    }
  }

  /** Hands a notification to the app's listeners; one that throws doesn't stop the others. */
  private deliver(listeners: Set<(data: NotificationData) => void>, data: NotificationData): void {
    listeners.forEach((listener) => this.safely('a notification listener', () => listener(data)));
  }

  /** Runs the app's callback; an error it throws is logged, never thrown on. */
  private safely(what: string, callback: () => void): void {
    try {
      callback();
    } catch (e) {
      this.error(`${what} threw`, e);
    }
  }

  private error(message: string, cause?: unknown): void {
    if (this.logErrors) console.error(`[Kirora] ${message}`, cause ?? '');
  }

  onNewPushToken(token: string): void {
    if (typeof token !== 'string' || token === '') {
      this.error('onNewPushToken needs the token');
      return;
    }
    if (!this.destroyed) this.fire('onNewPushToken', () => this.native.onNewPushToken(token));
  }

  onNotificationClicked(listener: (data: NotificationData) => void): () => void {
    return this.listen(this.clickListeners, listener);
  }

  onNotificationReceived(listener: (data: NotificationData) => void): () => void {
    return this.listen(this.receivedListeners, listener);
  }

  private listen(
    listeners: Set<(data: NotificationData) => void>,
    listener: (data: NotificationData) => void
  ): () => void {
    if (this.destroyed) return () => undefined;
    listeners.add(listener);
    this.syncNotificationEvents();
    return () => {
      listeners.delete(listener);
      this.syncNotificationEvents();
    };
  }

  /** Never after destroy: the native module may serve a newer client by then. */
  private syncNotificationEvents(): void {
    if (this.destroyed) return;
    const clicked = this.clickListeners.size > 0;
    const received = this.receivedListeners.size > 0;
    this.fire('Turning notification events on or off', () => this.native.setNotificationEvents(clicked, received));
  }
}

/**
 * A native module's rejection as one of the SDK's errors. The modules reject with a code
 * (`USER_TOKEN_ERROR`, `KIRORA_API_ERROR` with `status`, `code` and `retryAfterMs` in `userInfo`,
 * anything else for a setup or network problem) and the native SDK's message.
 */
export function errorFromNative(e: unknown): KiroraError {
  const native = (e ?? {}) as { code?: unknown; message?: unknown; userInfo?: Record<string, unknown> | null };
  const message = (typeof native.message === 'string' ? native.message : String(e)).replace(/^Kirora: /, '');
  const info = native.userInfo ?? {};
  switch (native.code) {
    case 'USER_TOKEN_ERROR':
      return new UserTokenError(message, e);
    case 'KIRORA_API_ERROR':
      return new KiroraApiError(
        typeof info.status === 'number' ? info.status : 0,
        typeof info.code === 'string' ? info.code : undefined,
        message,
        typeof info.retryAfterMs === 'number' ? info.retryAfterMs : undefined
      );
    default:
      return new KiroraError(message, e);
  }
}
