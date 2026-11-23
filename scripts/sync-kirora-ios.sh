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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -d "$source" ]; then
  checkout="$(cd "$source" && pwd -P)"
  mkdir -p "$target"
  case "$checkout/" in
    "$(cd "$target" && pwd -P)/"*)
      echo "The source is the bundled copy itself: give a kirora-ios tag or another checkout" >&2
      exit 1 ;;
  esac
  ref="local $(git -C "$checkout" rev-parse HEAD 2>/dev/null || echo unknown)"
else
  checkout="$work/checkout"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$source" https://github.com/kiroratech/kirora-ios.git "$checkout"
  ref="$source $(git -C "$checkout" rev-parse HEAD)"
fi

# Built aside, then swapped in: a failed copy leaves the bundled one as it was.
staged="$work/kirora-ios"
mkdir -p "$staged/Sources"
cp -R "$checkout/Sources/Kirora" "$staged/Sources/Kirora"
cp -R "$checkout/Sources/KiroraNotificationService" "$staged/Sources/KiroraNotificationService"
# Kirora.podspec isn't used (this package's podspec builds the sources), but kept so a change to
# its frameworks or resources shows in the diff, for kirora-react-native.podspec to follow.
cp "$checkout/Kirora.podspec" "$checkout/KiroraNotificationService.podspec" "$checkout/LICENSE" "$staged/"
echo "$ref" > "$staged/VERSION"
rm -rf "$target"
mkdir -p "$(dirname "$target")"
mv "$staged" "$target"
echo "ios/vendor/kirora-ios now holds kirora-ios $ref"
