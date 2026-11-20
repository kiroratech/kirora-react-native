import { Platform } from 'react-native';

/**
 * Where the example app sends. By default the fake client API in `e2e/fake-kirora.mjs`, which the
 * Android emulator reaches at 10.0.2.2 and the iOS simulator at localhost. To try staging, change
 * these two values (never commit a staging key).
 */
export const API_URL = Platform.OS === 'android' ? 'http://10.0.2.2:4010' : 'http://localhost:4010';
export const CLIENT_KEY = 'kirora_pk_e2e';

/** User tokens the harness signs in with. The fake API accepts any token unless told to refuse it. */
export const TOKENS = {
  userA: 'e2e-token-user-a',
  userB: 'e2e-token-user-b',
  refused: 'e2e-token-refused'
};
