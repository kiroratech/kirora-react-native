# Kirora React Native example

A single-screen Android app that exercises the SDK: sign in, track events and screens, consent, and push.
All the SDK code is in [`App.tsx`](App.tsx).

## Run

1. Configure the app:

   ```sh
   cp src/config.example.json src/config.local.json
   ```

   Set `apiUrl` and your workspace's public `clientKey` in `src/config.local.json` (it is git-ignored).

2. Mint a test user token. The token secret stays on your machine and never goes in the app; in a real app your
   backend signs this token:

   ```sh
   KIRORA_TOKEN_SECRET=<token secret> node scripts/mint-token.js test-user-1
   ```

3. Pack the SDK from the parent folder, then install the dependencies. The example installs the SDK from a
   tarball, because React Native only links native modules that are listed in `package.json`:

   ```sh
   npm run sdk
   npm install
   ```

4. Make the Kirora Android SDK available to Gradle. It is resolved from `mavenLocal()` until it is published:

   ```sh
   cd ../../kirora-android
   ./gradlew :kirora-sdk:publishToMavenLocal :kirora-sdk-push:publishToMavenLocal
   ```

5. Build and install on a device:

   ```sh
   cd example
   npm run android -- --mode release
   ```

   A release build bundles the JavaScript, so no Metro server is needed.

**Windows:** the Android C++ build fails with "No such file or directory" when the project path is long (Android's
CMake and ninja ignore the OS long-path setting). Build from a short path, for example a copy at `C:\kre`.

## Push

1. Register an Android app with package `io.kirora.rndemo` in your Firebase project.
2. Put its `google-services.json` in `android/app/` (git-ignored).
3. Set `pushEnabled` to `true` in `src/config.local.json`.
4. Add the Firebase service account key to the push app in your Kirora workspace so it can send, and copy that
   app's App ID into `pushAppId` in `src/config.local.json`. The SDK needs it when the workspace has more than one
   Android push app.
5. Rebuild.

## Notes

- iOS is not included.
