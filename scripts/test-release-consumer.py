#!/usr/bin/env python3
"""Build an external SwiftPM URL consumer from the produced source archive (no device)."""
import argparse, pathlib, subprocess, tarfile, tempfile
parser = argparse.ArgumentParser()
parser.add_argument('archive', type=pathlib.Path)
args = parser.parse_args()
def run(command, cwd):
    subprocess.run(command, cwd=cwd, check=True)
with tempfile.TemporaryDirectory(prefix='bugcapsule-swiftpm-consumer-') as temporary:
    root = pathlib.Path(temporary)
    with tarfile.open(args.archive.resolve()) as archive:
        archive.extractall(root, filter='data')
    source = next(p for p in root.iterdir() if p.is_dir())
    run(['python3', 'scripts/verify-patch-runtime.py'], source)
    run(['git', 'init', '-q'], source)
    run(['git', 'add', '.'], source)
    run(['git', '-c', 'user.name=Release QA', '-c', 'user.email=qa@example.invalid', 'commit', '-qm', 'Archive snapshot'], source)
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
    remote = root / 'source.git'
    run(['git', 'clone', '--bare', str(source), str(remote)], root)
    consumer = root / 'consumer'
    (consumer / 'Sources/Consumer').mkdir(parents=True)
    (consumer / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Consumer", platforms: [.iOS(.v15)],
 products: [.library(name: "Consumer", type: .dynamic, targets: ["Consumer"])],
 dependencies: [.package(url: "%s", revision: "%s")],
 targets: [.target(name: "Consumer", dependencies: [
 .product(name: "BugCapsule", package: "source"),
 .product(name: "BugCapsulePatch", package: "source")])])
''' % (remote.as_uri(), revision))
    (consumer / 'Sources/Consumer/Consumer.swift').write_text('''import BugCapsule
import BugCapsulePatch
public func fixtureContract() -> PatchContract {
 PatchContract(id: "fixture", inputSchema: "{\\"type\\":\\"integer\\"}", outputSchema: "{\\"type\\":\\"integer\\"}")
}
public func coreAndPatchBindingTypes() -> (BugCapsuleConfig.Type, BugCapsulePatchBinding.Type) {
 (BugCapsuleConfig.self, BugCapsulePatchBinding.self)
}
''')
    run(['xcodebuild', '-scheme', 'Consumer', '-destination', 'generic/platform=iOS Simulator',
         '-derivedDataPath', str(root / 'derived'), '-jobs', '2', 'CODE_SIGNING_ALLOWED=NO', 'build'], consumer)
print('PASS: source archive -> bare Git URL -> external core+patch SwiftPM consumer.')
