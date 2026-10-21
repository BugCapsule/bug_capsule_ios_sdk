#!/bin/sh
# Prepares (does not publish) a release of the BugCapsule iOS SDK:
# builds and tests the package, then writes a source archive and checksum to
# dist/. SwiftPM consumers use the git tag; the archive is for review/mirrors.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
version=$(sed -n 's/^let sdkVersion = "\(.*\)"/\1/p' Sources/BugCapsule/Runtime/Session.swift)
[ -n "$version" ] || { echo "cannot read sdkVersion" >&2; exit 1; }
echo "BugCapsule iOS $version"
swift build -c release
swift test
mkdir -p dist
name="bugcapsule-ios-$version"
tar -czf "dist/$name.tar.gz" --exclude .build --exclude .swiftpm --exclude dist --exclude xcuserdata \
  -s "|^\.|$name|" ./Package.swift ./README.md ./Sources ./Tests ./spec-fixtures ./Examples ./scripts
shasum -a 256 "dist/$name.tar.gz" | tee "dist/$name.tar.gz.sha256"
echo "Release checklist: tag v$version, push the tag (SwiftPM resolves by tag)."
