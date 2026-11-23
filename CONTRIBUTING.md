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
`ios/vendor/kirora-ios/VERSION` records the source. `scripts/check-bundled-ios.sh`, run by CI
and before every release, fails when the copy differs from its tag or was synced from a local
checkout.

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

## Releasing

Merging to `main` publishes to npm when `package.json`'s version isn't there yet
(`.github/workflows/release.yml`, as in kirora-web). `scripts/release-plan.mjs` picks the
dist-tag: a prerelease goes to `next`, an older maintenance version to `release-<major>.<minor>`,
anything else to `latest`. A merge that doesn't change the version publishes nothing.

To release, bump `version` in `package.json` and add a `CHANGELOG.md` entry in a pull request;
publishing happens when it merges. The workflow publishes only after the typecheck, tests and
bundled-SDK check pass, and publishes the tarball it packed, with provenance.

npm authenticates the workflow through trusted publishing (no token is stored). Setup, once:

1. Publish a placeholder from a maintainer's machine, since trusted publishing needs an existing
   package: with `version` set to `0.0.1-stage` locally (not committed), run
   `npm publish --tag stage --access public --provenance=false` (provenance only works from CI).
2. On npmjs.com, in the package's Settings → Trusted publishing → GitHub Actions: organization
   `kiroratech`, repository `kirora-react-native`, workflow `release.yml`, environment `npm`.
3. In this repository's GitHub settings, create the environment `npm`.
