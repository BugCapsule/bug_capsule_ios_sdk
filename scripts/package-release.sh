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
python3 scripts/verify-patch-runtime.py
swift build -c release -j 2
swift test -j 2
mkdir -p dist
name="bugcapsule-ios-$version"
COPYFILE_DISABLE=1 tar -czf "dist/$name.tar.gz" --exclude .build --exclude .swiftpm --exclude dist --exclude xcuserdata --exclude .DS_Store \
  -s "|^\.|$name|" ./Package.swift ./README.md ./CHANGELOG.md ./LICENSE ./docs ./Sources ./Tests ./spec-fixtures ./Examples ./scripts ./Packages
( cd dist && shasum -a 256 "$name.tar.gz" ) | tee "dist/$name.tar.gz.sha256"
echo "Release checklist: tag v$version, push the tag (SwiftPM resolves by tag)."
