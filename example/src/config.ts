import local from './config.local.json';

/**
 * Build-time settings. Edit `src/config.local.json` (git-ignored; copy `config.example.json`).
 * The client key is public by design. The user token is a short-lived test token minted with
 * `scripts/mint-token.js`; a real app asks its own backend for one.
 */
export const CONFIG = {
  apiUrl: local.apiUrl,
  clientKey: local.clientKey,
  userToken: local.userToken,
  /** Turn on once `android/app/google-services.json` for this app's package exists. */
  pushEnabled: local.pushEnabled,
  /** The App ID of this app in your Kirora workspace. Needed when the workspace has several push apps for Android. */
  pushAppId: local.pushAppId,
};
