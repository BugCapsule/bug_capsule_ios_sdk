#!/usr/bin/env python3
"""Regression: a release cannot silently omit or alter its bundled runtime."""
import pathlib, shutil, subprocess, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
class RuntimePackageTests(unittest.TestCase):
    def test_intact_missing_modified_and_extra_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / 'scripts').mkdir()
            shutil.copy2(ROOT / 'scripts/verify-patch-runtime.py', root / 'scripts')
            package = root / 'Packages/BugCapsulePatch'
            package.mkdir(parents=True)
            shutil.copy2(ROOT / 'Packages/BugCapsulePatch/runtime-provenance.json', package)
            shutil.copytree(ROOT / 'Packages/BugCapsulePatch/Binaries', package / 'Binaries')
            def valid():
                results = [subprocess.run(['python3', *flags, str(root / 'scripts/verify-patch-runtime.py')], capture_output=True).returncode == 0
                           for flags in ([], ['-O'])]
                self.assertEqual(results[0], results[1], 'Optimization must not disable release checks')
                return results[0]
            self.assertTrue(valid())
            framework = package / 'Binaries/BcpatchRuntime.xcframework'
            binary = next(p for p in framework.rglob('BcpatchRuntime') if p.is_file())
            original = binary.read_bytes()
            binary.unlink()
            self.assertFalse(valid(), 'Missing native binary must fail')
            binary.write_bytes(original + b'changed')
            self.assertFalse(valid(), 'Changed native binary must fail')
            binary.write_bytes(original)
            (framework / 'untracked-file').write_text('unexpected')
            self.assertFalse(valid(), 'Extra shipped file must fail')
if __name__ == '__main__': unittest.main()
