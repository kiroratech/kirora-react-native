#!/usr/bin/env bash
# Fails when ios/vendor/kirora-ios isn't exactly the kirora-ios release its VERSION file names.
# Run by CI and before every release.
set -euo pipefail
cd "$(dirname "$0")/.."
tag="$(cut -d' ' -f1 ios/vendor/kirora-ios/VERSION)"
if [ "$tag" = local ]; then
  echo "ios/vendor/kirora-ios was synced from a local checkout: sync it from a release tag" >&2
  exit 1
fi
scripts/sync-kirora-ios.sh "$tag"
if [ -n "$(git status --porcelain -- ios/vendor)" ]; then
  git status --short -- ios/vendor
  echo "ios/vendor/kirora-ios differs from kirora-ios $tag: run scripts/sync-kirora-ios.sh $tag" >&2
  exit 1
fi
