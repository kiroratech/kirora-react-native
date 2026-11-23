import { EMPTY_STATE, type KiroraBackend, type KiroraState } from './backend';
import type { PushPermission, PushStatus } from './types';

/**
 * Why there is no native SDK: not linked (Expo Go, a build made before installing), the web,
 * or another platform it doesn't run on (react-native-windows, react-native-macos).
 */
export type Unavailable = 'unlinked' | 'web' | 'unsupported-platform';

const MESSAGES: Record<Unavailable, string> = {
  unlinked:
    "[Kirora] The native module isn't linked, so Kirora does nothing. It needs native code: use a " +
    'development build (`npx expo run:ios`, `run:android`) rather than Expo Go, then rebuild the app ' +
    'after installing. In tests, mock it with `jest.mock(\'@kirora/react-native\', () => require(\'@kirora/react-native/jest\'))`.',
  web:
    '[Kirora] @kirora/react-native runs on Android and iOS only, so Kirora does nothing here. On the ' +
    'web (react-native-web, Expo web), use Kirora\'s web SDK, @kirora/web.',
  'unsupported-platform': '[Kirora] @kirora/react-native runs on Android and iOS only, so Kirora does nothing on this platform.'
};

/**
 * Where there is no native SDK: every call is a safe no-op, so the app keeps working, and one
 * error says why nothing is sent.
 */
export class UnavailableBackend implements KiroraBackend {
  constructor(logErrors: boolean, why: Unavailable) {
    if (logErrors) console.error(MESSAGES[why]);
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
  onPushRegistered(): void {}
  onNotificationClicked(): () => void {
    return () => undefined;
  }
  onNotificationReceived(): () => void {
    return () => undefined;
  }
}
