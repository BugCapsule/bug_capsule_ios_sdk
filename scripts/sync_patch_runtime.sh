#!/usr/bin/env bash
# Copies the runtime built by bug_capsule_patch_engine/tools/build-native.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="${BCPATCH_ENGINE:-$HERE/../../bug_capsule_patch_engine}"
rm -rf "$HERE/Packages/BugCapsulePatch/Binaries"
mkdir -p "$HERE/Packages/BugCapsulePatch/Binaries"
cp -R "$ENGINE/dist/apple/BcpatchRuntime.xcframework" "$HERE/Packages/BugCapsulePatch/Binaries/"
echo "synced runtime from $ENGINE/dist"
