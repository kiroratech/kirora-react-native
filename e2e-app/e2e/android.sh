#!/usr/bin/env bash
# Prepares a local Android run of the e2e app against the fake Kirora API:
# publishes the local Kirora Android SDK, builds the app, boots the emulator, starts the fake
# API and installs the app. The tests are `e2e/android.mjs`. Usage, from the repo root:
# e2e-app/e2e/android.sh
set -euo pipefail

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$ANDROID_HOME/platform-tools/adb"
AVD="${AVD:-kirora_e2e}"
PORT="${FAKE_KIRORA_PORT:-4010}"
KIRORA_ANDROID="${KIRORA_ANDROID:-$(cd "$(dirname "$0")/../../.." && pwd)/kirora-android}"
APP="$(cd "$(dirname "$0")/.." && pwd)"
LOGS="${LOGS:-$APP/e2e/.logs}"
mkdir -p "$LOGS"

# Only when kirora-android changed since the last publish: its commit plus uncommitted changes.
stamp="$(cd "$KIRORA_ANDROID" && { git rev-parse HEAD; git status --porcelain; git diff; } | shasum | cut -d' ' -f1)"
if [ "$stamp" = "$(cat "$LOGS/sdk-publish.stamp" 2>/dev/null)" ]; then
  echo "1/5 the Kirora Android SDK in Maven Local is current"
else
  echo "1/5 publishing the Kirora Android SDK from $KIRORA_ANDROID"
  (cd "$KIRORA_ANDROID" && ./gradlew :kirora-sdk:publishToMavenLocal :kirora-sdk-push:publishToMavenLocal \
    --console=plain > "$LOGS/sdk-publish.log" 2>&1) || { tail -20 "$LOGS/sdk-publish.log"; exit 1; }
  echo "$stamp" > "$LOGS/sdk-publish.stamp"
fi

echo "2/5 building the SDK's JavaScript and the e2e app"
(cd "$APP/.." && npm run build > "$LOGS/sdk-build.log" 2>&1)
(cd "$APP/android" && ./gradlew assembleDebug -Pe2eBundle -PreactNativeArchitectures=arm64-v8a \
  --console=plain > "$LOGS/app-build.log" 2>&1) || { grep -A12 "What went wrong" "$LOGS/app-build.log"; exit 1; }

echo "3/5 booting emulator $AVD"
if ! "$ADB" devices | grep -q "emulator-"; then
  nohup "$ANDROID_HOME/emulator/emulator" -avd "$AVD" -no-snapshot -no-audio -no-boot-anim \
    > "$LOGS/emulator.log" 2>&1 &
fi
"$ADB" wait-for-device
until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done

echo "4/5 starting the fake Kirora API on :$PORT"
# Restarted every run, so it always answers as the current fake-kirora.mjs does.
pkill -f "e2e/fake-kirora.mjs" 2>/dev/null || true
FAKE_KIRORA_PORT="$PORT" nohup node "$APP/e2e/fake-kirora.mjs" > "$LOGS/fake-kirora.log" 2>&1 &
until curl -sf -o /dev/null -X POST "localhost:$PORT/__test/reset"; do sleep 1; done

echo "5/5 installing the app (its JS bundle is inside: no Metro needed)"
# No route to a Metro on this machine: the app runs the bundle it carries, as the tests expect.
"$ADB" reverse --remove tcp:8081 2>/dev/null || true
"$ADB" install -r "$APP/android/app/build/outputs/apk/debug/app-debug.apk" > /dev/null
echo "ready: run the tests with: cd e2e-app && node e2e/android.mjs"
