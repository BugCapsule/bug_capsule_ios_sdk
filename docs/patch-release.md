# iOS patch SDK release packaging

The root package exports BugCapsule, BugCapsuleXCTest and the optional iOS-only
BugCapsulePatch product. All resolve from the same canonical Git URL and version.
The runtime is committed under Packages/BugCapsulePatch/Binaries so a tagged clone
is self-contained. The package uses a local binary target within that fetched
repository, not an external download URL. No Git LFS service or pre-existing release
asset is required to resolve it. Existing nested local checkouts have a compatibility
product forwarding to the root implementation.

`Packages/BugCapsulePatch/runtime-provenance.json` records the actual engine source,
compiled-input equivalence and SHA256 for every XCFramework file. The binary was
built from dcc0808 with Rust1.99.1/locked dependencies and reused byte-for-byte from
the verified private candidate. It was not rebuilt from the later equivalent source;
this is not an independent reproducibility attestation. The manifest records the
exact later comparison commit. Device arm64 and Simulator arm64/x86_64 are included.

Run `python3 scripts/verify-patch-runtime.py` before packaging. Run
`sh scripts/package-release.sh` for core build/tests and a complete source archive
with checksum, then `python3 scripts/test-release-consumer.py dist/bugcapsule-ios-0.4.1-beta.5.tar.gz`.
The consumer test unpacks that archive, creates an isolated bare Git remote and
builds an external URL-dependent iOS Simulator consumer importing both products.
It does not install or execute an app. Core macOS tests remain separate.

After review and CI, the release operator may tag the approved commit as
v0.4.1-beta.5, push that tag to the canonical repository and attach the source
archive/checksum plus runtime provenance to its GitHub prerelease. These scripts
never create tags, push, upload or publish. Do not replace an existing release tag
or archive. Public availability does not qualify a distribution profile, customer
application, production fleet or store policy.
