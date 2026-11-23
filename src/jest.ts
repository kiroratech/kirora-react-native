/**
 * A stand-in for `@kirora/react-native` in an app's Jest tests, where there is no native code:
 *
 * ```js
 * jest.mock('@kirora/react-native', () => require('@kirora/react-native/jest'));
 * ```
 *
 * Every method is a `jest.fn()` that answers what a working, signed-out SDK would, so tests can
 * assert on calls (`expect(kirora.track).toHaveBeenCalledWith('Order Completed', …)`).
 */
import { EMPTY_STATE, type KiroraState } from './backend';
import type { KiroraOptions } from './types';

export { KiroraApiError, KiroraError, UserTokenError } from './errors';
export { SDK_VERSION } from './version';

declare const jest: { fn: <T extends (...args: any[]) => any>(implementation?: T) => T };

const state = (): KiroraState => ({ ...EMPTY_STATE, isInitialized: true, trackingConsent: true });

export class Kirora {
  static active: Kirora | null = null;
  readonly isAvailable = true;

  constructor(readonly options: KiroraOptions) {
    Kirora.active = this;
  }

  identify = jest.fn(async (_token?: string) => undefined);
  logout = jest.fn(async () => undefined);
  track = jest.fn((_name: string, _properties?: Record<string, unknown>) => undefined);
  trackScreenView = jest.fn((_name: string) => undefined);
  setTrackingConsent = jest.fn((_granted: boolean) => undefined);
  setPushConsent = jest.fn(async (_granted: boolean) => undefined);
  requestPushPermission = jest.fn(async () => 'granted' as const);
  getPushStatus = jest.fn(async () => 'disabled' as const);
  setPushEnabled = jest.fn(async (_enabled: boolean) => undefined);
  flush = jest.fn(async () => undefined);
  destroy = jest.fn(() => undefined);
  getState = jest.fn(async () => state());
  onNotificationClicked = jest.fn((_listener: (data: Record<string, string>) => void) => () => undefined);
  onNotificationReceived = jest.fn((_listener: (data: Record<string, string>) => void) => () => undefined);
  onNewPushToken = jest.fn((_token: string) => undefined);
  onPushRegistered = jest.fn((_installationId: string) => undefined);
}
