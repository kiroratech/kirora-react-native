# Kirora React Native SDK

[![CI](https://github.com/kiroratech/kirora-react-native/actions/workflows/ci.yml/badge.svg)](https://github.com/kiroratech/kirora-react-native/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Send what signed-in users do in your React Native app to Kirora, and register their devices
for Kirora push. One TypeScript API over Kirora's native Android and iOS SDKs, which store
events and handle sessions, consent, retries and notifications.

**0.1.0**, the first release. A successful JavaScript call does not prove delivery: test the
native artifacts your app resolves.

## Requirements

| Component | Declared | Tested |
| --- | --- | --- |
| React Native | Peer dependency `>=0.71.0`. Uses legacy native-module APIs through the interop layer. | 0.88.1 only |
| Android | API 24+, `compileSdkVersion` 35 or later | JDK 17, Kotlin 2.2.0, Gradle 9.4.1, `compileSdkVersion` 37 |
| iOS | iOS 13+, Swift 5.9 | |
| Expo | A development build. Expo Go can't load native modules. | SDK 58 |
| Web | Not supported: `isAvailable` is false and every call does nothing. Use `@kirora/web`. | |

## Install

```sh
npm install @kirora/react-native
cd ios && pod install
```

Rebuild the native app; a Metro reload can't add a native module.

**Expo:** also install
[`@kirora/expo-plugin`](https://github.com/kiroratech/kirora-expo-plugin#readme), add it to
`plugins` in your app config, then run `npx expo prebuild` and rebuild.

Without the native module, `kirora.isAvailable` is false and every method does nothing
(push methods return `unsupported`).

**Native SDKs.** Android links `io.kirora:android-sdk` and `io.kirora:android-sdk-push` (which
adds Firebase Messaging) 0.1.0 from Maven Central; `ext.kiroraAndroidSdkVersion` in the root
project overrides the version. iOS needs nothing from CocoaPods trunk: this package bundles the
Kirora iOS SDK 0.1.0 (`ios/vendor/kirora-ios`, version in its `VERSION` file) and builds it
into its own pod. Don't also add Kirora iOS to the app: two copies would each register for
push. An iOS SDK update comes with a new release of this package.

## Quick start: a first event

**1. Create one client**, once, at startup, outside render functions (a new one replaces the
previous). The client key is your
workspace's public key (`kirora_pk_…`), safe to ship. `authApi` is your own server client.

```ts
import { Kirora } from '@kirora/react-native';

export const kirora = new Kirora({
  clientKey: 'kirora_pk_REPLACE_ME',
  requireTrackingConsent: true,
  fetchUserToken: async () => (await authApi.fetchKiroraToken()).token,
});
```

**2. Sign the user token on your server.** Keep the secret that signs user tokens, and every
server API key, on your server. Your server signs an HS256 JWT whose `sub` is the contact's
`externalId`, with `iat` and `exp` in seconds, valid for at most 24 hours and issued at most
60 seconds ahead of Kirora's clock. A contact is one person in your workspace; Kirora matches
the signed-in user to the contact whose `externalId` equals the token's `sub`.

**3. Identify** after sign-in and on every app start while the user is signed in:

```ts
try {
  await kirora.identify(); // or kirora.identify(tokenFromYourServer)
} catch (error) {
  // KiroraError. Don't log tokens.
}
```

**4. Record consent.** `requireTrackingConsent: true` tracks nothing until
`setTrackingConsent(true)`; without it, tracking is on unless the user refused.

```ts
kirora.setTrackingConsent(true); // once the user agrees
```

**5. Track:**

```ts
kirora.track('Order Completed', { order_id: 'ORD-1042', total: 12500, currency: 'NGN' });
kirora.trackScreenView('Checkout');
```

**6. Check it in Kirora** on the contact whose `externalId` is the token's `sub`. Events go
in batches; `await kirora.flush()` sends now.

There are no anonymous contacts. Events tracked before the first `identify()` wait on the
device and go to the next user who signs in. Nothing is sent while nobody is signed in.

## Quick start: a first push

1. **Configure a push app in Kirora** for each platform: FCM for Android, APNs or Firebase for
   iOS.
2. **Set up the native side**: [Android](#android--fcm) and [iOS](#ios--apns-or-firebase)
   below. On Expo, the plugin does the iOS part.
3. **Turn push on** in the client's options:

   ```ts
   push: true
   // or: push: { pushAppId: 'YOUR_PUSH_APP_ID' }
   ```

4. **Ask for permission** after `identify()`. A granted permission registers the device for
   the signed-in user.

   ```ts
   const permission = await kirora.requestPushPermission();
   // 'granted' | 'denied' | 'unanswered' | 'unsupported'
   ```

5. **For marketing push, save consent** with `setPushConsent(true)` (see
   [Consent](#consent-and-device-push-settings)). Transactional push needs the permission and
   a registered device, not push consent; marketing push needs all three.
6. **Send a test push** to that contact from Kirora, then check that it arrives, that a tap
   opens its link, and that the campaign reports the delivery and the tap.
   `await kirora.getPushStatus()` answers `enabled` when this device can receive Kirora push.

### Android / FCM

Add your app's `android/app/google-services.json`, apply the Google Services Gradle plugin
(`com.google.gms.google-services`) as Firebase's Android setup describes, and configure the FCM
push app in Kirora. On Expo, `android.googleServicesFile` does both.
The SDK's messaging service shows Kirora's messages (`kirora = "true"`) and ignores others.
If your app has its own `FirebaseMessagingService`, forward to Kirora as the native Android
SDK describes. `kirora.onNewPushToken(token)` forwards a token from a JS messaging library, and
`kirora.onPushRegistered(installationId)` a Firebase installation ID.

Appearance options take resource names:

```ts
push: {
  smallIcon: 'ic_notification',
  accentColor: '#FF5500',
  defaultChannelId: 'kirora_default',
  defaultChannelName: 'Notifications',
  onForegroundNotification: (data) => data.plan !== 'muted',
}
```

### iOS / APNs or Firebase

Enable Push Notifications and configure the matching Kirora push app. With
`KiroraAppDelegateProxyEnabled = NO`, wire the callbacks as the
[native iOS guide](https://github.com/kiroratech/kirora-ios#readme) describes, with
`import kirora_react_native` in place of `import Kirora`. A Firebase push app needs Firebase's
iOS integration, which `push: true` doesn't install.

Delivery reports, images and buttons need a Notification Service Extension with
`KiroraNotificationService`, and pushes sent with `mutable-content: 1`. Set it up as the
native iOS guide describes (the Expo plugin adds it), taking the pod from this package in the
extension's Podfile target:

```ruby
pod 'KiroraNotificationService', :path => File.join(File.dirname(`node --print "require.resolve('@kirora/react-native/package.json')"`), 'ios', 'vendor', 'kirora-ios')
```

It can't read the client's options: with a custom `apiUrl`, set the same value as
`KiroraApiUrl` in the extension's Info.plist, or as `ios.apiUrl` in the Expo plugin.

## Identity and sign-out

The SDK also calls `fetchUserToken` 60 seconds before expiry, on returning to the foreground
with an expired token, and after Kirora refuses one. No token (`null`, `undefined`, `''`) or no
answer within 30 seconds is a failure: `identify()` rejects with `UserTokenError`.

`onAuthenticationFailed` reports a token failure in the background: `fetch_failed`
or `refused` (Kirora refused a fresh token). It fires once per failure, not per retry, and
not for errors a method rejects with or during sign-out. Events keep waiting.

```ts
onAuthenticationFailed: (reason) => {
  // Restore your session, then call identify() again.
},
```

Each event belongs to the user signed in when it was tracked. If another user signs in
without `logout()`, the earlier user's waiting events are never sent as the new user. They
are sent when that earlier user signs in again, unless the queue evicted them first.

### Sign-out

Call `logout()` only from your app's sign-out, and let it finish before the next sign-in.

```ts
await kirora.logout();
```

Within five seconds it tries to send waiting events and detach the device, then forgets the
user and unsent events. Neither is guaranteed.

- **A failed detach** (offline, say) is saved and retried for 24 hours, including after a
  relaunch. It uses a per-installation device secret that can only detach the device. A
  final refusal from Kirora ends the retries.
- **With nobody signed in** (after a relaunch, before `identify()`), `logout()` still
  detaches the device. It drops only the waiting events that continued a signed-in user's
  visit, so they never pass to the next user. A visitor who never signed in keeps their
  events. With `trackSessions: false` nothing is dropped.

`destroy()` only stops this client's timers and listeners (hot reload, tests). It isn't sign-out.

## Consent and device push settings

| API | Controls |
| --- | --- |
| `setTrackingConsent(granted)` | Behavioural tracking: events, screens, sessions, lifecycle events and app-open times. Stored on the device. |
| `setPushConsent(granted)` | The signed-in user's marketing push choice, saved by Kirora. |
| `requestPushPermission()` | The OS notification prompt. Not marketing consent. |
| `setPushEnabled(enabled)` | This device's push on/off, kept across sign-out. Never prompts. |

After `setTrackingConsent(false)`, native code stops tracking and forgets the waiting events.
JavaScript also drops later `track` and `trackScreenView` calls, even if the native call
failed. Data Kirora already accepted is not removed.

Save marketing consent after `identify()`, and handle failure:

```ts
try {
  await kirora.setPushConsent(userAcceptedMarketingPush);
  // Show the choice as saved only now.
} catch (error) {
  // Keep the previous choice and offer a retry.
}
```

Push registration and reports continue while tracking is refused. `setPushEnabled(false)` detaches the device; `true`, or a
granted permission request, registers it again.

## Track events and screens

Set `trackSessions` (default `true`) and `trackAppLifecycle` (default `false`) at
construction. A session is a visit: it starts with `Session Started`, time in the foreground
keeps it alive, and it ends after 30 minutes in the background. The SDK queues up to 1,000
events, evicting the oldest. It sends at 20 events, every 30 seconds and on going to the
background. `await kirora.flush()` sends now, within consent and server backoff; it isn't a
delivery receipt. Events land on the user's contact, where segments, journeys, campaigns and
conversion goals use them.

### Naming events and properties

Kirora matches event names exactly (`Order Completed` is not `order completed`).

- **Events:** Title Case, object then past-tense action (`Plan Upgraded`). Values that vary
  go in properties. Up to 128 characters; 1,000 distinct names per workspace.
- **Properties:** snake_case (`order_id`), up to 64 characters, 16 KB in all as JSON. Keep
  each type stable; send amounts in major units (naira, not kobo).
- **Reserved:** `contact.` names are refused. Send `Screen Viewed`, `Session Started` and
  `Application …` events only through the SDK's own options and methods.

The server enforces these limits. Properties must be JSON values; `undefined` members are
left out and dates become ISO strings. Anything else (cycles, functions, `Map`, `NaN`, a
throwing getter) drops the event with a log. `track` never throws.

### Redact app properties before native storage

```ts
beforeSend: (event) => {
  if (event.name === 'Sensitive Action') return null;
  const properties = { ...event.properties };
  delete properties.email;
  return { ...event, properties };
},
```

Copy and delete; don't destructure (`const { email, ...rest } = …`). React Native's Babel
turns a `__proto__` property into the copy's prototype, and a non-plain object drops the event.

`beforeSend` sees `track` and `trackScreenView` events and must return synchronously (the first
events wait until native tracking consent is known). Return the event, or `null` to drop it; a
promise or an error also drops it. `context` is empty: native code adds it later, and automatic
events skip the hook. Keep it free of side effects.

## Notifications and links

```ts
const status = await kirora.getPushStatus();
// 'enabled' | 'disabled' | 'denied' | 'unanswered' | 'unsupported'

const offClick = kirora.onNotificationClicked((data) => { /* observe the tap */ });
const offReceived = kirora.onNotificationReceived((data) => { /* Android only */ });
// When the owning component unmounts:
offClick();
offReceived();
```

Native code reports the tap and opens its link. `onNotificationClicked` runs after native
code has waited up to 1.5 seconds for that report, which may not have finished. Taps before
the first listener (the latest ten) are delivered when it attaches.

Notification values are untrusted strings (buttons arrive as JSON text; iOS omits `aps`).
`onForegroundNotification` must answer within about 1.5 seconds, or the push is shown.

### Route push links once

```ts
handleDeepLink: (url) => {
  if (!url.startsWith('myapp://orders/')) return false;
  routeAppUrl(url); // your router
  return true;
},
```

Return (or resolve to) `true` only when the app handled the URL; otherwise native code opens
it. After 1.5 seconds native code opens it anyway. On a cold start it waits up to ten seconds
for the client. Don't also open the URL in `onNotificationClicked`.

On iOS, claim your universal links in `handleDeepLink`, or list their hosts in Info.plist
`KiroraUniversalLinkHosts` (the Expo plugin fills it from `ios.associatedDomains`). Otherwise
an `https` link opens in Safari or the app that owns it.

## State and errors

```ts
const state = await kirora.getState();
// isInitialized, isIdentified, deviceId, sessionId, pushToken,
// trackingConsent, pushConsent, queuedEventCount
```

`getState` never rejects, prompts or calls the network; what it can't read is `false`,
`null` or `0`.

`pushConsent` is the choice `setPushConsent()` last saved from this device for the signed-in
user. `false` also means no choice is recorded here, and changes made elsewhere aren't
fetched. Read the authoritative consent from your backend.

`KiroraError` is the base error. `UserTokenError` covers getting a token. `KiroraApiError`
adds `status`, `code`, `retryAfterMs` and `retryable`. `identify()` and `setPushConsent()`
reject on failure. `logout()`, `flush()` and `setPushEnabled()` never reject; they log.

## Storage and privacy

The native SDKs keep events, consent, sessions and device state in the app's storage. User
tokens stay in memory. This package stores nothing itself.

Each event's `context` holds the device id, session, locale, time zone, app name, version,
build and bundle id or package name, OS name and version, screen size and density, and
device manufacturer and type. No device model or network details. Kirora also records each
request's IP address, user agent and sending library.

Push reporting sends the app and OS version, language and time zone at registration; app
open times (only with tracking consent); and when a Kirora notification is shown or tapped.
`beforeSend` can't redact any of this. No hardware or advertising id is sent; the device id
is deleted with the app.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `kirora.isAvailable` is false | The native module isn't linked: rebuild the native app (Expo: prebuild and a development build, not Expo Go). |
| `identify()` rejects with `UserTokenError` | `fetchUserToken` returned no token or took over 30 seconds. |
| Events don't appear | The user is identified and tracking consent is granted; `getState()` shows `queuedEventCount`. |
| `getPushStatus()` is `denied` | System settings block notifications (or, on Android, Kirora's channel): send the user to `Linking.openSettings()`. |
| iOS pushes lack images, buttons or delivery reports | The Notification Service Extension is set up, and pushes carry `mutable-content: 1`. |
| An iOS push's `https` link opens Safari | Handle it in `handleDeepLink` or list its host in `KiroraUniversalLinkHosts`. |

## Differences from Kirora's other SDKs

| Here | Elsewhere | Why |
| --- | --- | --- |
| `onNotificationClicked(listener)` returns a remove function | `addNotificationClickListener` / `removeNotificationClickListener` | The shared interface's wrapper form |
| `onNotificationReceived` | Android SDK's foreground listener | Android only; iOS has no such event |
| `isAvailable` | Not on native or web SDKs | False without the native module |
| `beforeSend` sees `track` and `trackScreenView` only, with empty `context` | Also `Session Started` and lifecycle events, with context | It runs in JavaScript before native code |
| `getState()` returns a promise | Synchronous on iOS, `suspend` on Android | Read across the bridge |
| `trackScreenView(name)` | `trackPageView()` on web | Platform |

## More

- **Testing your app:** mock the SDK in Jest with
  `jest.mock('@kirora/react-native', () => require('@kirora/react-native/jest'));`. The mock
  records calls with `jest.fn()` and does nothing else.
- **Examples:** [`example/`](example) (bare React Native, Android) and the
  [Expo example](https://github.com/kiroratech/kirora-expo-plugin/tree/main/example).
- **Changes:** [CHANGELOG](CHANGELOG.md). **Contributing:** [CONTRIBUTING](CONTRIBUTING.md).
- **License:** MIT. See [LICENSE](LICENSE).
