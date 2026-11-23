import type { KiroraBackend, KiroraState } from './backend';
import { NativeBackend, NativeEventEmitterLike, NativeKiroraModule } from './NativeBackend';
import type { KiroraOptions, NotificationData, PushPermission, PushStatus } from './types';
import { type Unavailable, UnavailableBackend } from './UnavailableBackend';

/** The native module to use instead of the runtime's, for tests. @internal */
export interface KiroraInternals {
  native?: NativeBridge | null;
}

/** The native module and its emitter. */
interface NativeBridge {
  module: NativeKiroraModule;
  emitter: NativeEventEmitterLike;
}

declare const require: (id: string) => any;

/**
 * The Kirora client SDK.
 *
 * ```ts
 * const kirora = new Kirora({ clientKey: 'kirora_pk_…', fetchUserToken: () => myServer.kiroraToken() });
 * await kirora.identify();          // at every start while signed in, and after sign-in
 * kirora.track('Order Completed', { order_id: 'ORD-1042' });
 * await kirora.logout();            // on sign-out
 * ```
 *
 * Every call goes to the native Kirora Android or iOS SDK. Where the native module isn't linked
 * (Expo Go), and on other platforms (web, macOS, Windows), every call does nothing and one error
 * says why. Create it once, at startup; a newer
 * client destroys the older one. No call blocks the app or throws because Kirora is unreachable.
 */
export class Kirora {
  /** The most recently created instance. */
  static active: Kirora | null = null;

  /**
   * False where the native module isn't linked (Expo Go) and on platforms other than Android and
   * iOS (web: use `@kirora/web`): then nothing is tracked or sent.
   */
  readonly isAvailable: boolean;

  private readonly backend: KiroraBackend;

  constructor(options: KiroraOptions, internals: KiroraInternals = {}) {
    const previous = Kirora.active;
    const found = internals.native === undefined ? nativeFromRuntime() : internals.native ?? 'unlinked';
    if (typeof found === 'object') {
      this.backend = new NativeBackend({ ...options, clientKey: (options.clientKey ?? '').trim() }, found.module, found.emitter);
    } else {
      this.backend = new UnavailableBackend(options.logLevel !== 'none', found);
    }
    this.isAvailable = typeof found === 'object';
    Kirora.active = this;
    // After this one's set-up, which replaced the native client: no longer current, the old one
    // only stops its own listeners.
    previous?.destroy();
  }

  /**
   * Signs the user in with `token`, or with one from `fetchUserToken` when omitted; registers the
   * device for push if allowed and sends waiting events. Call it at every start while the user is
   * signed in. Rejects with `UserTokenError` when there's no token, `KiroraApiError` when Kirora
   * refuses it, or `KiroraError` for a setup problem (no token and no `fetchUserToken`, a bad
   * `apiUrl`). A push registration that fails otherwise is logged.
   */
  identify(token?: string): Promise<void> {
    return this.backend.identify(token);
  }

  /**
   * Attempts to send the user's waiting events and detach the device within 5 seconds, then
   * forgets the user and their unsent events; a detach that fails is retried for 24 hours. Call
   * it only from the app's sign-out. Never rejects; safe to call twice.
   */
  logout(): Promise<void> {
    return this.backend.logout();
  }

  /** Queues an event with a copy of `properties` as they are now, and returns at once. Never throws. */
  track(name: string, properties?: Record<string, unknown>): void {
    this.backend.track(name, properties);
  }

  /** Records a `Screen Viewed` event. Screens are named by the app. */
  trackScreenView(name: string): void {
    this.backend.trackScreenView(name);
  }

  /**
   * The user's tracking choice, remembered on the device. `false` stops behavioural collection
   * (even without `requireTrackingConsent`) and forgets events, visit state and app opens still
   * waiting. Operational push (registration, delivery and tap reports, cleanup) is unaffected.
   * Anything but `true` or `false` is logged and ignored: the choice stays as it was.
   */
  setTrackingConsent(granted: boolean): void {
    this.backend.setTrackingConsent(granted);
  }

  /**
   * The signed-in user's consent to marketing push, recorded with proof; independent of the OS
   * permission. Resolves once Kirora recorded it, and rejects (`KiroraApiError`, `UserTokenError`,
   * or `KiroraError` for a network or setup problem) when it didn't.
   */
  setPushConsent(granted: boolean): Promise<void> {
    return this.backend.setPushConsent(granted);
  }

  /** The platform's prompt, then registration if granted. */
  requestPushPermission(): Promise<PushPermission> {
    return this.backend.requestPushPermission();
  }

  /**
   * This device's push, for an app's "notifications on/off" setting: `enabled`, `disabled`, or the
   * permission (`denied`, `unanswered`, `unsupported`). Never prompts; waits for a sign-in under way.
   */
  getPushStatus(): Promise<PushStatus> {
    return this.backend.getPushStatus();
  }

  /**
   * The device's own push on/off, kept on the device for whoever signs in next. `false` detaches
   * the device; `true` registers again if permission is already granted, never prompting. Not
   * marketing consent: that is `setPushConsent`. Never rejects.
   */
  setPushEnabled(enabled: boolean): Promise<void> {
    return this.backend.setPushEnabled(enabled);
  }

  /**
   * Attempts to send the current user's waiting events now, without bypassing consent or
   * `Retry-After`. Resolves when the attempt stops, which doesn't mean every event was accepted.
   */
  flush(): Promise<void> {
    return this.backend.flush();
  }

  /**
   * Stops this client's timers and listeners at once, without sending or deleting anything: for
   * hot reload, tests and apps that replace their client. Waiting events stay on the device.
   */
  destroy(): void {
    const current = Kirora.active === this;
    this.backend.destroy(current);
    if (current) Kirora.active = null;
  }

  /**
   * A snapshot of the SDK's state: identity, ids, consent and the waiting queue. Never rejects:
   * what can't be read comes back empty (`false`, `null`, `0`).
   */
  getState(): Promise<KiroraState> {
    return this.backend.getState();
  }

  /**
   * A tap on a Kirora notification or one of its buttons. A tap that launched the app is delivered
   * when you attach. Returns the unsubscribe.
   */
  onNotificationClicked(listener: (data: NotificationData) => void): () => void {
    return this.backend.onNotificationClicked(listener);
  }

  /** A Kirora push arriving, in any app state it is drawn in (Android, native SDK). Returns the unsubscribe. */
  onNotificationReceived(listener: (data: NotificationData) => void): () => void {
    return this.backend.onNotificationReceived(listener);
  }

  /** Android: forward a new FCM token when your messaging library hands you one. The iOS SDK reads its own. */
  onNewPushToken(token: string): void {
    this.backend.onNewPushToken(token);
  }

  /**
   * Android: forward a Firebase installation ID when your messaging library hands you one instead of
   * a token (with `firebase_messaging_installation_id_enabled`). The iOS SDK reads its own.
   */
  onPushRegistered(installationId: string): void {
    this.backend.onPushRegistered(installationId);
  }

  /** @internal */
  static resetForTesting(): void {
    Kirora.active?.destroy();
  }
}

/**
 * The native module and its emitter, on Android or iOS when the module is linked; otherwise why
 * not: not linked (Expo Go), the web, or another platform (macOS, Windows).
 */
function nativeFromRuntime(): NativeBridge | Unavailable {
  try {
    const rn = require('react-native');
    const os = rn.Platform.OS;
    if (os === 'web') return 'web';
    if (os !== 'android' && os !== 'ios') return 'unsupported-platform';
    const module = rn.NativeModules?.KiroraSdk as NativeKiroraModule | undefined;
    if (!module) return 'unlinked';
    return { module, emitter: new rn.NativeEventEmitter(module) };
  } catch {
    return 'unlinked';
  }
}
