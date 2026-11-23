export type LogLevel = 'none' | 'error' | 'debug';

/** Why `onAuthenticationFailed` was called. Same values on every Kirora SDK. */
export type AuthenticationFailureReason = 'fetch_failed' | 'refused';

/** The answers of `requestPushPermission()`. Same values on every Kirora SDK. */
export type PushPermission = 'granted' | 'denied' | 'unanswered' | 'unsupported';

/**
 * The answers of `getPushStatus()`. The platform's permission comes first; with it granted,
 * `enabled` when this device is registered for the signed-in user, `disabled` otherwise.
 * `denied` means blocked in system settings: the permission, or on Android Kirora's
 * notification channel turned off (the permission then still reads `granted`).
 */
export type PushStatus = 'enabled' | 'disabled' | 'denied' | 'unanswered' | 'unsupported';

/** A Kirora push as the app sees it: the sender's own data, plus Kirora's keys. */
export type NotificationData = Record<string, string>;

export interface KiroraPushOptions {
  /** Passed to Kirora as is when the workspace has several push apps for the platform. */
  pushAppId?: string;
  /** Android: name of the small monochrome drawable for notifications (`ic_notification`). Falls back to the manifest meta-data, then the launcher icon. */
  smallIcon?: string;
  /** Android: accent colour of notifications (`#RRGGBB`). */
  accentColor?: string;
  /** Android: id and name of the default channel the SDK creates at start (`kirora_default`, `Notifications`). */
  defaultChannelId?: string;
  defaultChannelName?: string;
  /**
   * Decides whether a Kirora push is shown while the app is open. It is shown by default; return
   * `false` to hold one back. Must answer within about 1.5 s, or the push is shown.
   */
  onForegroundNotification?: (data: NotificationData) => boolean | Promise<boolean>;
}

/** An event as `beforeSend` sees it: a detached copy, so changing it changes nothing else. */
export interface BeforeSendEvent {
  name: string;
  properties: Record<string, unknown>;
  /** Empty: the native SDK adds the context after redaction. */
  context: Record<string, unknown>;
}

export interface KiroraOptions {
  /** The workspace's public key (`kirora_pk_…`), safe to ship. */
  clientKey: string;
  /**
   * Asks your server for a signed user token; called by `identify()` without a token and when
   * Kirora refuses an expired one. One that hasn't answered after 30 seconds counts as failed.
   */
  fetchUserToken?: () => Promise<string | null | undefined>;
  /**
   * Called when the user's token fails outside a method call (a send in the background):
   * `fetch_failed` when `fetchUserToken` threw, gave no token or didn't answer in time, `refused`
   * when Kirora refused a fresh one. Once per failure, not per retry: again only after a request
   * with the user's token succeeded or `identify()` was called. Never for a failure `identify()`
   * or `setPushConsent()` rejects with, nor while signing out. Ask the user to sign in again, or
   * call `identify()` once your session is fixed.
   */
  onAuthenticationFailed?: (reason: AuthenticationFailureReason) => void;
  /** `true`, or options: register this device for push. */
  push?: boolean | KiroraPushOptions;
  /**
   * Collect no behavioural events, visit state or app-open times until `setTrackingConsent(true)`.
   * Default `false`.
   */
  requireTrackingConsent?: boolean;
  /** `Session Started` when a visit begins, `context.sessionId` on every event. Default `true`. */
  trackSessions?: boolean;
  /** `Application Installed`, `Opened`, `Updated` and `Backgrounded`. Default `false`. */
  trackAppLifecycle?: boolean;
  /** Default `error`. */
  logLevel?: LogLevel;
  /** Default `https://api.kirora.io`. */
  apiUrl?: string;
  /**
   * Redacts or drops an event the app tracks (`track`, `trackScreenView`) before it reaches the
   * native SDK, with a copy of its name and properties (`context` is empty). Return the event
   * with fields changed or removed, or `null` to drop it. It must answer at once: an error, a
   * promise or values JSON can't hold drop the event. The native SDK's automatic events
   * (`Session Started`, lifecycle events) carry no app values and don't pass through it.
   * Never called while tracking consent is refused: those events are dropped before it.
   * Until the native SDK has answered whether a remembered choice allows tracking (just after
   * start), the app's events wait for that answer before it runs.
   */
  beforeSend?: (event: BeforeSendEvent) => BeforeSendEvent | null;
  /**
   * Called with a push's link when it is tapped; return (or resolve to) `true` when the app
   * opened it itself. Otherwise the native SDK opens it. Asked across the bridge: answer within
   * 1.5 s, or the native SDK opens the link itself.
   */
  handleDeepLink?: (url: string) => boolean | Promise<boolean>;
}
