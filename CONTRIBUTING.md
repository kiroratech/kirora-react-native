# Contributing

## Build and test

```sh
npm install
npm run typecheck
npm test
npm run build
```

`example/` (a bare React Native app) and `e2e-app/` (the SDK's test host, used by CI) have their
own READMEs.

## The bundled iOS SDK

`ios/vendor/kirora-ios` is a copy of kirora-ios, which this package's pod builds (CocoaPods trunk
has no Kirora pod). Don't edit it by hand. Refresh it from a release tag:

```sh
scripts/sync-kirora-ios.sh 0.2.0
```

or, while developing, from a local checkout (`scripts/sync-kirora-ios.sh /path/to/kirora-ios`).
`ios/vendor/kirora-ios/VERSION` records the source. CI fails when the copy differs from its tag,
or was synced from a local checkout.

## The Android SDK

The bridge depends on `io.kirora:android-sdk` and `io.kirora:android-sdk-push` from Maven
Central. To try a kirora-android checkout, publish it to Maven Local
(`./gradlew :kirora-sdk:publishToMavenLocal :kirora-sdk-push:publishToMavenLocal`); `e2e-app/`
and `example/` prefer that copy.

## CI

Pull requests and pushes to `main` (skipping Markdown, `docs/` and `LICENSE` changes) run the
typecheck, build, Jest, the Android bridge unit tests, Android and iOS-simulator builds of
`e2e-app/`, and the bundled-SDK check. A manual run can build against another kirora-android
and kirora-ios ref (`native_sdk_ref`).
