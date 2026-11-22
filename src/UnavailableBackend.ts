import { EMPTY_STATE, type KiroraBackend, type KiroraState } from './backend';
import type { PushPermission, PushStatus } from './types';

const UNAVAILABLE_MESSAGE =
  "[Kirora] The native module isn't linked, so Kirora does nothing. It needs native code: use a " +
  'development build (`npx expo run:ios`, `run:android`) rather than Expo Go, then rebuild the app ' +
  'after installing. In tests, mock it with `jest.mock(\'@kirora/react-native\', () => require(\'@kirora/react-native/jest\'))`.';

const OTHER_PLATFORM_MESSAGE =
  '[Kirora] @kirora/react-native runs on Android and iOS only, so Kirora does nothing here. On the ' +
  'web (react-native-web, Expo web), use Kirora\'s web SDK, @kirora/web.';

/** Why there is no native SDK: not linked (Expo Go, a build made before installing), or a platform it doesn't run on (web). */
export type Unavailable = 'unlinked' | 'unsupported-platform';

/**
 * Where there is no native SDK: every call is a safe no-op, so the app keeps working, and one
 * error says why nothing is sent.
 */
export class UnavailableBackend implements KiroraBackend {
  constructor(logErrors: boolean, why: Unavailable = 'unlinked') {
    if (logErrors) console.error(why === 'unsupported-platform' ? OTHER_PLATFORM_MESSAGE : UNAVAILABLE_MESSAGE);
  }

  async identify(): Promise<void> {}
  async logout(): Promise<void> {}
  track(): void {}
  trackScreenView(): void {}
  setTrackingConsent(): void {}
  async setPushConsent(): Promise<void> {}
  async requestPushPermission(): Promise<PushPermission> {
    return 'unsupported';
  }
  async getPushStatus(): Promise<PushStatus> {
    return 'unsupported';
  }
  async setPushEnabled(): Promise<void> {}
  async flush(): Promise<void> {}
  destroy(): void {}
  async getState(): Promise<KiroraState> {
    return { ...EMPTY_STATE };
  }
  onNewPushToken(): void {}
  onNotificationClicked(): () => void {
    return () => undefined;
  }
  onNotificationReceived(): () => void {
    return () => undefined;
  }
}
