# Kirora React Native SDK

Report what signed-in users do in your React Native app to Kirora, so segments, journeys,
campaigns and conversion goals can act on it, and connect their devices to Kirora push
notifications. The package exposes one TypeScript API backed by Kirora's native Android and
iOS SDKs. Native code owns event storage, sessions, consent, retries and notification
handling; this package forwards calls and runs your JavaScript callbacks.

**Preview: 0.1.0.** Not yet published to npm. See [What has been verified](#what-has-been-verified)
for what was tested and how. Validate the exact native artifacts your app resolves:
successful JavaScript calls alone do not establish delivery.

## Terms used here

These follow Kirora's API guides and the shared client SDK interface.

| Term | Meaning |
| --- | --- |
| **Contact** | One person in your Kirora workspace. Events, devices and consent belong to a contact. |
| **User** | The person signed in to your app. Kirora matches them to the contact whose `externalId` equals the user token's `sub`. |
| **Client key** | The workspace's public key (`kirora_pk_…`). Safe to ship in the app; it acts only together with a user token. |
| **User token** | A short-lived token your server signs for one user. Never signed in the app. |
| **Identify** | `identify()`: sign the user in to Kirora, so the device and events are tied to their contact. |
| **Event** | Something the user did, with a name (`Order Completed`) and **properties** (`{ order_id: 'ORD-1042' }`). |
| **Session** | A visit: it starts with `Session Started` and ends after 30 minutes with no activity. |
| **Device** | This app on this phone. Its **device id** is a random value the SDK creates, never a hardware or advertising id. |
| **Tracking consent** | The user's choice about behavioural tracking (events, screens, sessions), stored on the device. |
| **Push consent** | The contact's consent to marketing push, saved by Kirora. Separate from tracking consent and from the OS notification permission. |
| **Sign out** | `logout()`: forget the user on this device and detach the device from their contact. |

There are no anonymous contacts in this version. Events tracked before the first
`identify()` wait on the device and are sent as the next user to sign in; nothing is sent
for a signed-out user.

## Requirements and installation

| Component | Current declaration and limits |
| --- | --- |
| React Native | Peer dependency `>=0.71.0`; the full version/architecture range has not been verified. The implementation uses legacy native-module APIs through React Native's interoperability layer. |
| Android | Runs on API 24+. Compile with `compileSdkVersion` 35 or later: the native SDK's AndroidX dependencies need it. |
| iOS | Podspec declares iOS 13+ and Swift 5.9. Use the higher deployment minimum required by your React Native/Xcode combination. |
| Expo | A native development build is required. Expo Go cannot load this package's native modules. The Expo config plugin is a separate package, `@kirora/expo-plugin`. |
| Web | Not supported. On react-native-web or Expo web, `isAvailable` is false and every call is a no-op; use Kirora's web SDK, `@kirora/web`, there. |
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

The client key is public. **Keep the token secret (the key user tokens are signed with)
and every server API key on your server.** The SDK calls your server for a user token; it
never signs one in the app. Your server signs an HS256 JWT whose `sub` is the contact's
`externalId` (your own stable id for the user), with `iat` and `exp` in seconds. A token
may be valid for at most 24 hours and may not be issued more than 60 seconds ahead of
Kirora's clock.

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
native code decides whether an answer is still current. The native SDKs call
`fetchUserToken` 60 seconds before the current token's `exp`, when the app returns to the
foreground with an expired token, and after Kirora refuses one; there is no separate
React Native option for this. Answering no token (`null`, `undefined` or an empty string)
counts as a failed fetch: `identify()` rejects with `UserTokenError`.

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

Events tracked before sign-in stay on the device and go to the next user who signs in;
they are never sent anonymously. The native SDKs tie each event to its user when it is
tracked: if another user signs in without `logout()`, the earlier user's waiting events
still go as that user, never as the new one. Validate this with the exact native versions
you release.

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
  total: 12500,
  currency: 'NGN',
  products: [{ product_id: 'p1', name: 'Yirgacheffe Beans', price: 6250, quantity: 2 }],
});
kirora.trackScreenView('Checkout');
```

`Order Completed` and its properties are one of Kirora's standard e-commerce events; see
Kirora's e-commerce events guide for the rest (`Product Viewed`, `Checkout Started`…).

### Naming events and properties

Kirora reads events by exact name, so a journey waiting for `Order Completed` never starts
for `order completed`.

- **Event names:** Title Case, object then past-tense action: `Plan Upgraded`,
  `Order Completed`. One fixed name per action: anything that varies (an id, a price)
  goes in properties. Up to 128 characters; at most 1,000 distinct names per workspace.
- **Property names:** lowercase snake_case (`order_id`, `plan_name`), up to 64 characters,
  with the whole properties object at most 16 KB as JSON. Send the same type every time,
  and amounts in major units (naira, not kobo).
- **Reserved:** names beginning with `contact.` are Kirora's own and are refused.
  `Screen Viewed`, `Session Started` and the `Application …` lifecycle events have fixed
  meanings: send them through `trackScreenView`, `trackSessions` and
  `trackAppLifecycle` rather than with `track`.

The server enforces these limits; the SDK doesn't check them before sending. Properties are copied in JavaScript before crossing the bridge.
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

### Use the events in Kirora

Events land on the signed-in user's contact. You build on them in the Kirora dashboard or
through the server API, not in this SDK. With `Checkout Started` and `Order Completed`
tracked as above:

- **Segment:** "contacts with `Order Completed` at least twice in the last 90 days". A
  segment is evaluated when used, so it changes as new events arrive. Rules can read a
  nested property with a dotted path, such as `products.0.price`.
- **Journey:** triggered by `Checkout Started`, waits, then sends a push reminder, with an
  exit condition on `Order Completed` so a user who orders meanwhile gets no reminder.
- **Campaign:** one push send to a segment, now or at a set time. Marketing push reaches
  only contacts with push consent and a device that allows notifications.
- **Conversion goal:** counts `Order Completed` after a campaign or journey message, and
  sums `total` as revenue. Conversion goals need a paid plan.
- **Transactional push:** sent from your server to one contact by `externalId`, such as an
  order update. It needs no push consent, only a device that allows notifications.

Push campaigns and journeys reach this device only after `identify()` has registered it
(see [Set up push](#set-up-push)).

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
| `setPushEnabled(enabled)` | This device's push setting, retained across sign-out. Does not prompt. |

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
is refused. `setPushEnabled(false)` detaches the device; `true` registers again
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
[native iOS guide](https://github.com/kiroratech/kirora-ios#readme) describes. The
extension must hand back the push's own content (or its mutable copy), never a new empty
one, and call the content handler exactly once on every path. The wrapper's main-app pod does
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
On iOS, claim your own universal links in `handleDeepLink`. An `https` link it doesn't claim
opens in Safari, or in the installed app that owns it, even when the link is yours: React
Native's linking module accepts every web URL, so the native SDK doesn't ask the app delegate
about it unless the host is listed in Info.plist `KiroraUniversalLinkHosts`. This needs the
Kirora iOS SDK at `87bcf5b` or later; earlier versions could swallow the link.

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
properties, ownership/context, consent, sessions, device and registration state in
the app's storage. User tokens are kept in native memory only. Your application and
authentication libraries may have their own storage policies.

Each event carries a `context` beside its properties: the device id, the session, the
locale and time zone, the app's name, version, build and bundle id or package name, the
OS name and version, the screen's size and density, and the device's manufacturer and
type (`ios` or `android`). The device model and network details are not collected. Kirora
also records the IP address and user agent each request comes from, and the library that
sent it. Older
preview artifacts collected differently: verify the native artifact you ship before
making collection disclosures. `beforeSend` cannot redact native context or the push
reports below.

To report how push notifications perform, the SDK sends:
- the app's version, the OS version, and the device's language and time zone, when it
  registers the device;
- the time the app is opened or returns to the foreground;
- when a Kirora notification is shown or tapped.

Behavioural tracking consent also controls app-open times for influenced opens.
Push registration details, delivery receipts and notification taps are operational
push reports and are separate from behavioural tracking consent and marketing push
consent. Disabling behavioural tracking does not disable those operational reports.

It never sends hardware or advertising identifiers. The device id is a random value the
SDK creates and keeps in the app's own storage; it is deleted with the app.

## Differences from Kirora's other SDKs

The options, event names and behaviour match the native SDKs this package wraps. Where
the React Native API differs:

| Here | Elsewhere | Why |
| --- | --- | --- |
| `onNotificationClicked(listener)` answers a function that removes the listener | `addNotificationClickListener` / `removeNotificationClickListener` (web, Android, iOS) | Wrapper naming; see the open item below |
| `onNotificationReceived` | Android SDK's foreground notification listener | Android only: iOS has no equivalent event |
| `isAvailable` (property) | Not on native or web SDKs | False where the native module isn't linked |
| `beforeSend` sees `track` and `trackScreenView` events only, with empty `context` | Native and web SDKs also pass `Session Started` and lifecycle events, with context | It runs in JavaScript before the event crosses to native code; automatic native events carry no app values |
| `getState()` answers a promise | Synchronous on iOS, `suspend` on Android | Read across the bridge |
| `trackScreenView(name)` | `trackPageView()` on web | Platform |

Open item: the shared interface lists `addNotificationClickListener` for every SDK and
`onNotificationClicked` for wrappers. Until that is settled, this package keeps
`onNotificationClicked`.

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

## What has been verified

- **On every change (CI):** TypeScript typecheck, build and Jest tests; the Android bridge
  unit tests; Android and iOS-simulator builds of `e2e-app/`.
- **Android emulator:** the `e2e-app/` scenarios against a fake Kirora API.
- **Physical devices (21 Nov 2026):** an iPhone and an Android phone running Kirora's Expo
  example app (a pre-release build of this package, React Native 0.88.1) against Kirora's
  staging environment: `identify()` with a user token, events reaching the contact, push
  registration, a campaign push with an image shown on a locked iPhone and on Android,
  a tap opening an app link, and the dashboard counting the delivery, open and click.

Not verified: installing from npm and CocoaPods (nothing is published yet), the full React
Native version and architecture range, offline delivery and app termination on a device,
and `https` push links on a device with the iOS SDK's `87bcf5b` fix.

## License

MIT. See [LICENSE](LICENSE).
