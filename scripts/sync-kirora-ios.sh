#!/usr/bin/env bash
# Copies the Kirora iOS SDK into ios/vendor/kirora-ios. This package's pod compiles its
# Sources/Kirora, so apps get the SDK from npm: Kirora isn't on CocoaPods trunk, which is
# read-only from December 2026. The notification extension's pod (KiroraNotificationService) is
# copied with its podspec, for apps to add by path.
#
#   scripts/sync-kirora-ios.sh 0.2.0                # a kirora-ios release tag
#   scripts/sync-kirora-ios.sh /path/to/kirora-ios  # a local checkout, as it is
#
# ios/vendor/kirora-ios/VERSION records the source; CI checks the copy matches its tag.
set -euo pipefail

source="${1:?usage: scripts/sync-kirora-ios.sh <kirora-ios tag or checkout path>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
target="$root/ios/vendor/kirora-ios"

if [ -d "$source" ]; then
  checkout="$(cd "$source" && pwd)"
  ref="local $(git -C "$checkout" rev-parse HEAD 2>/dev/null || echo unknown)"
else
  checkout="$(mktemp -d)"
  trap 'rm -rf "$checkout"' EXIT
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$source" https://github.com/kiroratech/kirora-ios.git "$checkout"
  ref="$source $(git -C "$checkout" rev-parse HEAD)"
fi

rm -rf "$target"
mkdir -p "$target/Sources"
cp -R "$checkout/Sources/Kirora" "$target/Sources/Kirora"
cp -R "$checkout/Sources/KiroraNotificationService" "$target/Sources/KiroraNotificationService"
cp "$checkout/KiroraNotificationService.podspec" "$checkout/LICENSE" "$target/"
echo "$ref" > "$target/VERSION"
echo "ios/vendor/kirora-ios now holds kirora-ios $ref"
