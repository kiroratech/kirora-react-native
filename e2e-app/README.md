# e2e-app

The SDK's test host: one button per SDK call (`App.tsx`) and a log of what came back. It is not a
demo; for that, see `../example`.

- **CI** (`../.github/workflows/ci.yml`) builds it for Android and the iOS simulator against the
  `main` branches of `kirora-android` and `kirora-ios`, and runs the Android bridge unit tests.
- **Device tests** run it on an Android emulator against `e2e/fake-kirora.mjs`, a stand-in for
  Kirora's client API that records what the native SDK sent.

## Device tests (Android)

Needs JDK 17, the Android SDK with an AVD (`kirora_e2e` by default, or set `AVD`) and a
`kirora-android` checkout next to this repo (or set `KIRORA_ANDROID`). From the repo root:

```sh
e2e-app/e2e/android.sh            # publish the Android SDK if changed, build, boot, fake API, install
cd e2e-app && node e2e/android.mjs   # run every scenario, or name some
```

The test build carries its JavaScript bundle (`-Pe2eBundle`), so Metro is not needed. With several
devices attached, set `ANDROID_SERIAL`. `FAKE_KIRORA_PORT` moves the fake API (default 4010).

The tests tap buttons by `accessibilityLabel` and wait for each `[e2e] <button>: ok|error` log
line, so keep both when changing `App.tsx`.

## iOS

The Kirora iOS SDK comes with the package (`ios/vendor/kirora-ios`): `bundle exec pod install`
needs nothing else. To build against a kirora-ios checkout, run
`scripts/sync-kirora-ios.sh /path/to/kirora-ios` in the repository root first.
