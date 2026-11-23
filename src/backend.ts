import type { NotificationData, PushPermission, PushStatus } from './types';

/** A snapshot of the SDK's state (the native SDK is behind an async bridge, so state is read, not observed). */
export interface KiroraState {
  isInitialized: boolean;
  isIdentified: boolean;
  deviceId: string | null;
  sessionId: string | null;
  pushToken: string | null;
  trackingConsent: boolean;
  pushConsent: boolean;
  queuedEventCount: number;
}

/** What a client that isn't set up reports: nothing known. */
export const EMPTY_STATE: Readonly<KiroraState> = Object.freeze({
  isInitialized: false,
  isIdentified: false,
  deviceId: null,
  sessionId: null,
  pushToken: null,
  trackingConsent: false,
  pushConsent: false,
  queuedEventCount: 0
});

/** What the `Kirora` class needs from whatever does the work: the native SDK, or nothing where it isn't linked. */
export interface KiroraBackend {
  identify(token?: string): Promise<void>;
  logout(): Promise<void>;
  track(name: string, properties?: Record<string, unknown>): void;
  trackScreenView(name: string): void;
  setTrackingConsent(granted: boolean): void;
  setPushConsent(granted: boolean): Promise<void>;
  requestPushPermission(): Promise<PushPermission>;
  getPushStatus(): Promise<PushStatus>;
  setPushEnabled(enabled: boolean): Promise<void>;
  flush(): Promise<void>;
  /** `stopNative`: this is the current client, so the native SDK stops too. */
  destroy(stopNative: boolean): void;
  getState(): Promise<KiroraState>;
  onNewPushToken(token: string): void;
  onPushRegistered(installationId: string): void;
  /** A tap on a Kirora notification or one of its buttons. A tap that launched the app is delivered when you attach. */
  onNotificationClicked(listener: (data: NotificationData) => void): () => void;
  /** A Kirora push arriving (Android). */
  onNotificationReceived(listener: (data: NotificationData) => void): () => void;
}
