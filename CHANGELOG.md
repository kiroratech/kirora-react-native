# Changelog

## 0.1.0

First release: events, screens, sessions, identity, consent and push over Kirora's native
Android SDK (`io.kirora:android-sdk` 0.1.0, Maven Central) and iOS SDK (0.1.0, bundled in this
package).

### Verified

- **CI** (pull requests and pushes to `main`, skipping Markdown, `docs/` and `LICENSE` changes):
  typecheck, build, Jest, Android bridge unit tests, Android and iOS-simulator builds of
  `e2e-app/`, and a check that the bundled iOS SDK matches its tag. Locally: `e2e-app/`
  scenarios on an Android emulator.
- **Devices** (Expo example, React Native 0.88.1, staging): an Android phone (21 Nov 2026) and
  an iPhone with iOS SDK `7b4049c` (22 Nov 2026). Identify, events, push registration, image
  push with the app killed, link tap, inbox, an action button opening an `https` link, sign-out
  detach, and an offline sign-out retried after relaunch. Rechecked on the iPhone with the
  bundled iOS SDK 0.1.0 (23 Nov 2026): registration, delivery report, tap and sign-out detach.
- **Not verified:** install from npm, `import kirora_react_native` for hand-wired push
  callbacks, the full React Native range, offline event delivery on a device, and the
  device-secret detach on a device (unit-tested in the iOS SDK).
