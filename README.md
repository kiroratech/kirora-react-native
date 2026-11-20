# Kirora React Native SDK

Track signed-in users' app activity and connect their devices to Kirora push notifications.
The package exposes one TypeScript API backed by Kirora's native Android and iOS SDKs.
Native code owns event storage, sessions, consent, retries and notification handling.

**Preview: 0.1.0.** Tested on an Android emulator against a fake Kirora API; iOS builds,
physical devices and push delivery are unverified. Validate the exact native artifacts used by
your host app. Successful JavaScript calls alone do not establish delivery.

## Requirements and installation

| Component | Current declaration and limits |
| --- | --- |
| React Native | Peer dependency `>=0.71.0`; the full version/architecture range has not been verified. The implementation uses legacy native-module APIs through React Native's interoperability layer. |
| Android | Runs on API 24+. Compile with `compileSdkVersion` 35 or later: the native SDK's AndroidX dependencies need it. |
| iOS | Podspec declares iOS 13+ and Swift 5.9. Use the higher deployment minimum required by your React Native/Xcode combination. |
| Expo | A native development build is required. Expo Go cannot load this package's native modules. No Expo config plugin is included. |
| Native releases | Android defaults to Kirora `0.1.0`; iOS depends on `Kirora ~> 0.1`. Verify the resolved artifacts contain the fixes needed by your app. |

Public npm/native repository installation has not been verified for this preview. Once
the package is available from your configured registry:

```sh
npm install @kirora/react-native
cd ios
pod install
```

Rebuild the native app after installation; a Metro reload cannot add a native module.
For Expo, use your native development-build workflow, such as `npx expo run:ios` or
`npx expo run:android`, and maintain the native configuration described below.

When the native module is missing, `kirora.isAvailable` is false. Methods become safe
no-ops, push methods return `unsupported`, and a diagnostic explains the missing build
unless logging is disabled. In particular, an unavailable module resolving
`setPushConsent` does not mean the server saved a choice. Check availability before
presenting integration success.

### Local native dependencies during development

Android links both `com.kirora:android-sdk` and `com.kirora:android-sdk-push`, even when
push is disabled in JavaScript. The latter brings Firebase Messaging and the notification
permission into the app. Until they are published, publish them to Maven Local from your
Kirora Android SDK checkout:

```sh
./gradlew :kirora-sdk:publishToMavenLocal :kirora-sdk-push:publishToMavenLocal
```

Then let your app's `android/build.gradle` resolve Kirora's packages from Maven Local. The app
resolves the wrapper's dependencies from its own repositories, not the wrapper's.

```groovy
allprojects {
    repositories {
        mavenLocal { content { includeGroup "com.kirora" } }
    }
}
```

The host root project's `ext.kiroraAndroidSdkVersion` can override the default native
version. Rebuild and inspect resolved dependencies after publishing a local correction;
a reused `0.1.0` label does not prove the artifact contains the latest source.

For a local iOS SDK, add its actual path to your host Podfile before running `pod install`:

```ruby
pod 'Kirora', :path => '/absolute/path/to/kirora-ios'
```

The wrapper podspec is discovered by autolinking. Do not register the same native module
a second time manually. The iOS SDK must include the `KiroraWrapper` interface; Android
must include `Kirora.setWrapperSdk`, wrapper callbacks and teardown support.

## Create one client

Create and retain the client at application startup, outside render functions. The
constructor does not ask for notification permission. The example's `authApi` is your
existing authenticated server client, returning `{ token: string }`.

```ts
import { Kirora } from '@kirora/react-native';

export const kirora = new Kirora({
  clientKey: 'kirora_pk_REPLACE_ME',
  requireTrackingConsent: true,
  fetchUserToken: async () => {
    const { token } = await authApi.fetchKiroraToken();
    return token;
  },
});
```

The client key is public. **Keep the token secret and all server API keys on your
server.** The SDK calls your server for a user token; it does not sign one in the app.
The server issues an HS256 JWT with `sub` equal to your stable user ID/contact
`externalId`, and `iat`/`exp` in seconds. The token must be valid for no more than
24 hours and not issued more than 60 seconds ahead of server time.

`requireTrackingConsent: true` waits for an explicit tracking grant. Otherwise tracking
is allowed by default unless a refusal is remembered.

`Kirora.active` is the latest instance. Constructing another destroys the previous
instance's JS listeners and replaces native configuration. Calls made before that, a
consent choice among them, reach the earlier client first. Retain one client rather than
constructing one per screen or rerender.

## Identify and sign out

Identify after your app authenticates the user, and on every authenticated app startup.
The native SDK keeps the user token in memory, not as restored login credentials.

```ts
import { KiroraError } from '@kirora/react-native';

try {
  await kirora.identify(); // Uses fetchUserToken.
  // Or: await kirora.identify(tokenFromYourAuthenticatedServer);
} catch (error) {
  if (error instanceof KiroraError) {
    // Record a safe failure state. Do not log tokens or sensitive error payloads.
  }
}
```

A token-provider request has a native 30-second round-trip limit. Requests carry IDs;
native code decides whether an answer is still current. Android's current native SDK
also supports proactive token refresh; it is not a separate React Native option.

When the token fails outside a method call (a background send), `onAuthenticationFailed`
says why: `fetch_failed` when `fetchUserToken` threw, gave no token or didn't answer in
time, `refused` when Kirora refused a fresh token. It's called once per failure, not per
retry: again only after a request with the user's token succeeded or `identify()` was
called. Never for a failure `identify()` or `setPushConsent()` rejects with, and not while
signing out. Events keep waiting on the device meanwhile.

```ts
const kirora = new Kirora({
  clientKey: 'kirora_pk_…',
  fetchUserToken: () => myServer.kiroraToken(),
  onAuthenticationFailed: (reason) => {
    // 'fetch_failed' or 'refused': restore your session, then call identify() again.
  },
});
```

Events captured before sign-in remain on the device and are adopted by the next
identified user; they are not sent anonymously. Native SDKs own association of captured
events with identities. A direct user switch must preserve the old user's event
ownership rather than send those events as the new user. Validate that behavior with
the exact native versions you release.

On application sign-out:

```ts
await kirora.logout();
```

Native logout attempts outgoing event delivery and device detachment within a shared
five-second deadline, then completes local sign-out. It does not promise that every event
was accepted or that the server revoked push immediately. Failed detachment can retry
with outgoing credentials held in memory, for up to 24 hours; process death, destruction
or a terminal refusal ends that cleanup. An offline sign-out cannot guarantee immediate
server-side revocation. Complete sign-out before starting the next authenticated flow.

`destroy()` stops this client's work/listeners without flushing or deleting its queued
events. It is intended for disposal, not application sign-out.

## Track events and screens

```ts
kirora.track('Order Completed', {
  order_id: 'ORD-1042',
  amount: 12500,
  currency: 'NGN',
});
kirora.trackScreenView('Checkout');
```

Use clear, consistent event names and property names. The server applies event-name and
property limits. Properties are copied in JavaScript before crossing the bridge.
Use JSON-compatible objects, arrays, strings, finite numbers, booleans and null. Object
members with `undefined` are omitted and dates become ISO strings. Cycles, functions,
`Map`, non-finite numbers and unsupported objects drop that event with a diagnostic.

Members are copied exactly, `__proto__` included. A getter that throws while the
properties (or `beforeSend`'s answer) are read drops that event with a diagnostic;
`track` never throws.

Sessions are on by default (`trackSessions: true`). Lifecycle events are off by default
(`trackAppLifecycle: false`). Set both options at construction, not per event.

Delivery follows the native SDK: the intended queue budget is 1,000 events and
1,000,000 serialized bytes, with oldest-first eviction. Sends are triggered at 20 events,
a 30-second interval and background transitions; batches are capped at 100 events and
200,000 bytes. Retries preserve event keys and must respect server backoff. These are
contract targets, not guarantees independently implemented or certified by this wrapper.

```ts
await kirora.flush();
```

Flush attempts delivery without intentionally bypassing consent or server Retry-After.
It is not a delivery receipt. Verify your resolved native artifacts against the backend
before release. Neither a successful call nor a schema check establishes live delivery.

### Redact app properties before native storage

```ts
const kirora = new Kirora({
  clientKey: 'kirora_pk_REPLACE_ME',
  requireTrackingConsent: true,
  beforeSend: (event) => {
    if (event.name === 'Sensitive Action') return null;
    const properties = { ...event.properties };
    delete properties.email;
    delete properties.phone;
    return { ...event, properties };
  },
});
```

Copy and delete as above rather than destructuring (`const { email, ...rest } = …`): React
Native's Babel turns a `__proto__` property into the copy's prototype there, and an answer that
is not a plain object drops the event.

`beforeSend` runs synchronously in JavaScript on explicit `track`/`trackScreenView`
events before forwarding. Return the event or null to drop it. A promise is not a
supported answer. Event name is retained by the SDK.

The hook receives **empty context**; native code adds automatic context later, and the
wrapper ignores returned context. It cannot redact native device/session context.
Native automatic session/lifecycle events do not pass through this wrapper hook, as the
shared wrapper contract permits. It never sees an event while tracking consent is
refused: such events are dropped before it. Just after start, until native code has said
whether a remembered choice allows tracking, the app's events wait for that answer before
the hook runs. Do not give it unrelated collection/network side effects.

## Consent and device push settings

| API | Controls |
| --- | --- |
| `setTrackingConsent(granted)` | Behavioural collection: app events, screens, sessions, lifecycle events and influenced app-open times. Stored locally by native code. |
| `setPushConsent(granted)` | Signed-in user's marketing push choice, saved by the server. |
| `requestPushPermission()` | Android/iOS notification authorization. Does not grant marketing consent. |
| `setPushEnabled(enabled)` | This installation's push setting, retained across user sign-out. Does not prompt. |

Apply tracking consent after your user chooses:

```ts
kirora.setTrackingConsent(userGrantedBehaviouralTracking);
```

The native consent design remembers refusals separately from the main preferences and
stops behavioural collection/sends on withdrawal. Stored-choice recovery depends on
consent mode and the refusal marker; it is not correct to claim all unreadable storage
always stops tracking. Review the resolved native version's storage guarantees.
SDK behavior cannot revoke information already accepted by the server.

Save marketing consent only after identify, and handle failure:

```ts
if (kirora.isAvailable) {
  try {
    await kirora.setPushConsent(userAcceptedMarketingPush);
    // Show the choice as saved only after this succeeds.
  } catch (error) {
    // Keep the previously saved choice and offer a retry.
  }
}
```

Marketing push needs both marketing consent and system authorization. Transactional push
does not require marketing consent. Operational registration, delivery/tap reports and
device detachment are separate from behavioural tracking and may continue while tracking
is refused. `setPushEnabled(false)` detaches the installation; `true` registers again
when system permission permits. A granted permission request also turns device push on.

## Set up push

Enable it in the retained client's options:

```ts
push: true
// Or: push: { pushAppId: 'YOUR_PLATFORM_PUSH_APP_ID' }
```

### Android / FCM

Configure Firebase and Google Services in your host app and supply its own
`android/app/google-services.json`. Configure the corresponding FCM push app in Kirora.
The native push library includes a messaging service and renders Kirora's data-only FCM
payloads, marked `kirora = "true"`. Other providers' messages should remain with their
own handlers.

If your app owns a `FirebaseMessagingService`, follow the native Android SDK's forwarding
integration for messages and token changes. `kirora.onNewPushToken(token)` forwards a token
from a JS messaging library; it does not forward a push message. Do not register multiple
paths that render/report the same message. Inspect the merged manifest when combining
messaging libraries.

Android appearance options are resource names/strings, not numeric native resource IDs:

```ts
push: {
  smallIcon: 'ic_notification',
  accentColor: '#FF5500',
  defaultChannelId: 'kirora_default',
  defaultChannelName: 'Notifications',
  onForegroundNotification: (data) => data.plan !== 'muted',
}
```

Provide the monochrome icon drawable in your app. Android owns channel sound/importance
settings; the SDK cannot silently override a user's channel preferences.

### iOS / APNs or configured Firebase target

Enable Push Notifications in the host app and configure its signing/entitlements and
matching Kirora push app. The native SDK installs token and notification callbacks at
launch; the wrapper includes the early launch hook. By default there is no additional
JS token forwarding for iOS.

If you disable native delegate proxying with `KiroraAppDelegateProxyEnabled = NO`, wire
the callbacks as described in the native iOS SDK's guide. Existing notification-center
delegates and other messaging libraries need validation in your host.

Delivered reporting and rich notifications require a Notification Service Extension.
Add `KiroraNotificationService` to that extension target and subclass its service as the
[native iOS guide](../kirora-ios/README.md) describes. The wrapper's main-app pod does
not create an extension target for you. If your configured push target uses Firebase,
include/configure the required Firebase iOS integration as well; `push: true` alone does
not install Firebase in an iOS host.

### Ask for permission and observe notifications

```ts
const permission = await kirora.requestPushPermission();
// 'granted' | 'denied' | 'unanswered' | 'unsupported'

const pushStatus = await kirora.getPushStatus();
// 'enabled' | 'disabled' | 'denied' | 'unanswered' | 'unsupported'

const offClick = kirora.onNotificationClicked((data) => {
  // Observe the tap; native code already owns reporting and link opening.
});
const offReceived = kirora.onNotificationReceived((data) => {
  // Android only. iOS does not emit this event.
});

// When the listener's owning screen/component is disposed:
offClick();
offReceived();
```

A tap reaches `onNotificationClicked` after the native SDK reported it, so the listener
may run up to 1.5 seconds after the tap.

Notification values are strings; structured sender data such as buttons is JSON text.
iOS's `aps` is omitted from this callback data. Treat payload values and URLs as untrusted.
`onForegroundNotification` is available on both native bridges, may return a promise,
and must answer within about 1.5 seconds. No timely answer means native default display.

### Route push links once

Provide `handleDeepLink` when constructing the client. The example's `routeAppUrl` is
your existing router operation, ready before you return true. The handler may also be
`async` and resolve to true or false:

```ts
handleDeepLink: (url) => {
  if (!url.startsWith('myapp://orders/')) return false;
  routeAppUrl(url);
  return true;
}
```

Return (or resolve to) true only when the app handled the URL; otherwise native code uses
its fallback. Answer fast: after 1.5 seconds native code opens the link itself. Validate the complete URL scheme/host/path for
your real routes. Do not open the same URL again in `onNotificationClicked`.

Native launch handling holds a cold-start tap's link for initial wrapper configuration
for up to ten seconds, then falls back. Subsequent JS routing answers have a 1.5-second
limit: a request that reaches JavaScript after it (a busy JS thread) isn't passed to
`handleDeepLink`, since native code has opened the link by then. Test cold starts with
your router.
On iOS, claim your universal links in `handleDeepLink` when needed, particularly in
scene-based hosts; do not assume every unhandled web URL stays in the app.

## Read state and handle failures

```ts
const state = await kirora.getState();
// isInitialized, isIdentified, deviceId, sessionId, pushToken,
// trackingConsent, pushConsent, queuedEventCount
```

`getState` never rejects: what can't be read comes back empty (`false`, `null`, `0`).
It doesn't prompt or call the network. `queuedEventCount` counts every waiting event, on
disk and in memory.
`isAvailable` means the native module was found, not that configuration, authentication
or delivery succeeded. State and flush completion are not server acceptance receipts.

`KiroraError` is the shared exception base. `UserTokenError` describes token acquisition
failures. `KiroraApiError` adds `status`, `code`, `retryAfterMs` and `retryable`. Identify
and marketing consent operations expose failures; logout, flush and device push toggles
swallow native failures with diagnostics. The unavailable runtime has safe no-ops.
Keep your own application UI honest about these distinctions.

## Storage and privacy

This package adds no JS persistence or delivery queue. The native SDKs store event
properties, ownership/context, consent, sessions, installation and registration state in
the app's storage. JWTs are kept in native memory. Your application and authentication
libraries may have their own storage policies.

The installation ID is random, not an advertising/hardware ID. Core event context follows
the shared contract: installation ID, session, locale/timezone and library, plus approved
mobile app, OS, screen and device manufacturer/model/type fields as native releases adopt
them. Network details are not part of the current contract. Older preview artifacts have
different collection behavior. Verify the actual native artifact before
making collection disclosures. Push registration
includes app/OS versions, locale/timezone and the platform token. Influenced app-open
times are behavioural and follow tracking consent; push delivery and tap reports are
operational. The wrapper hook cannot redact those native reports.

## Jest mock and source development

For host-app Jest tests without native code:

```js
jest.mock('@kirora/react-native', () => require('@kirora/react-native/jest'));
```

The mock records API calls with `jest.fn()`. It does not authenticate, persist state,
simulate a consent transition or deliver a notification. Use it for application wiring
assertions, not evidence that a native integration works.

From this package's source directory:

```sh
npm install
npm run typecheck
npm run build
npm pack --ignore-scripts
```

Build before packing so `lib/` contains JS and declarations. `npm test` runs the Jest suite.

- `example/`: a demo app to try the SDK on an Android device against a Kirora workspace (see its
  README).
- `e2e-app/`: a test host. CI (`.github/workflows/ci.yml`) builds it for Android and the iOS
  simulator and runs the Android bridge unit tests; `e2e-app/e2e/` runs it on an Android
  emulator against a fake Kirora API (see its README).

Still build your consuming Android/iOS app to validate autolinking, dependency resolution,
architecture support and push setup.

Verified so far: TypeScript build/typecheck and tests, the Android bridge unit tests, Android
builds of both apps, and the e2e scenarios on an Android emulator. iOS builds, physical
devices, push delivery and production publication remain unverified.

## License

MIT. See [LICENSE](LICENSE).
