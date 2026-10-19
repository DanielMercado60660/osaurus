#!/usr/bin/env python3
"""Packaging orchestration tests with fake build/sign/disk tools, no app proof."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

# Real shell scripts, filesystem, plist reads, hashes and size reporting; fake
# expensive/external tools. Each invocation is retained for order/flag checks.
TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
with (root / 'calls.jsonl').open('a') as f:
    f.write(json.dumps([name, args]) + '\n')
mode = os.environ.get('FIXTURE_MODE', '')
def value(flag): return args[args.index(flag) + 1]
def binary(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'fake executable\n')
    path.chmod(0o755)
if name == 'git':
    if 'rev-parse' in args: print('abc1234')
elif name == 'go':
    binary(pathlib.Path(value('-o')))
elif name == 'xcodebuild':
    assert 'ENABLE_CODE_COVERAGE=NO' in args and 'CLANG_COVERAGE_MAPPING=NO' in args
    assert 'CODE_SIGNING_ALLOWED=NO' in args
    if mode == 'build-failure': sys.exit(12)
    if 'archive' in args:
        # Archive's default install strip handles the app; forcing STRIP_* globally
        # also hits package static objects (swift-atomics) and fails.
        assert not any(a.startswith('STRIP_') for a in args)
        app = pathlib.Path(value('-archivePath')) / 'Products/Applications/osaurus.app'
        binary(app / 'Contents/MacOS/osaurus')
        pin = next(a.split('=', 1)[1] for a in args if a.startswith('OSAURUS_TS_HELPER_SHA256='))
        if mode == 'bad-pin': pin = 'bad'
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'OsaurusTSHelperSHA256': pin}))
    else:
        binary(pathlib.Path(value('-derivedDataPath')) / 'Build/Products/Release' / value('-scheme'))
elif name == 'codesign':
    # Signing changes bytes: catches accidental re-signing of the pinned helper.
    path = pathlib.Path(args[-1])
    if '--sign' in args and path.is_file():
        with path.open('ab') as f: f.write(b'signature\n')
    if mode == 'sign-failure' and '--verify' in args: sys.exit(13)
elif name == 'file':
    path = pathlib.Path(args[-1])
    print('Mach-O 64-bit executable arm64' if path.read_bytes().startswith(b'fake executable') else 'data')
elif name == 'xcrun':
    if args[0] == 'size':
        print('Segment __LLVM_COV' if mode == 'coverage' else 'Segment __TEXT')
elif name == 'hdiutil':
    if args[0] == 'create':
        assert value('-format') == 'UDZO'
        stage = pathlib.Path(value('-srcfolder'))
        assert (stage / 'Applications').readlink() == pathlib.Path('/Applications')
        assert (stage / 'Osaurus.app/Contents/Resources/SandboxRuntime/vmlinux').is_file()
        pathlib.Path(args[-1]).write_bytes(b'fake dmg')
'''


class PackagingTests(unittest.TestCase):
    def run_lane(self, mode='', identity=''):
        temporary = tempfile.TemporaryDirectory(prefix='packaging-', dir=ROOT / 'build/t10')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / 'scripts/build').mkdir(parents=True)
        (root / 'helpers/osaurus-ts').mkdir(parents=True)
        (root / 'App/osaurus').mkdir(parents=True)
        shutil.copy(ROOT / 'App/osaurus/osaurus.entitlements', root / 'App/osaurus')
        for script in ['build-fork-dmg.sh', 'build-ts-helper.sh']:
            shutil.copy(ROOT / 'scripts/build' / script, root / 'scripts/build')
        fetch = root / 'scripts/build/fetch_sandbox_kernel.sh'
        fetch.write_text('#!/bin/bash\nmkdir -p "$1"\nprintf kernel > "$1/vmlinux"\n')
        fetch.chmod(0o755)
        tools = root / 'tools'
        tools.mkdir()
        driver = tools / 'driver'
        driver.write_text(TOOL)
        driver.chmod(0o755)
        for name in ['git', 'go', 'xcodebuild', 'codesign', 'file', 'xcrun', 'hdiutil']:
            (tools / name).symlink_to('driver')
        env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'], FIXTURE_ROOT=str(root),
                   FIXTURE_MODE=mode, CODESIGN_IDENTITY=identity)
        result = subprocess.run(['bash', str(root / 'scripts/build/build-fork-dmg.sh')],
                                env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
        return root, result, calls

    def test_ad_hoc_bundle_and_pin(self):
        root, result, calls = self.run_lane()
        self.assertEqual(result.returncode, 0, result.stdout)
        app = root / 'build/fork/dmg-root/Osaurus.app'
        self.assertEqual(sorted(p.name for p in (app / 'Contents/Helpers').iterdir()),
                         ['osaurus', 'osaurus-plugin-host', 'osaurus-ts'])
        self.assertTrue((root / 'build/fork/Osaurus-fork-abc1234.dmg').exists())
        self.assertIn('before=', result.stdout)
        self.assertIn('Coverage check: no __LLVM_COV', result.stdout)
        sign_calls = [a for n, a in calls if n == 'codesign' and '--sign' in a]
        self.assertTrue(all(a[a.index('--sign') + 1] == '-' for a in sign_calls))
        self.assertFalse(any('--deep' in a for a in sign_calls))
        self.assertTrue(any('-ldflags' in a and '-s -w' in a for n, a in calls if n == 'go'))

    def test_developer_identity_propagates(self):
        identity = 'Developer ID Application: Fixture (TEAM123)'
        _, result, calls = self.run_lane(identity=identity)
        self.assertEqual(result.returncode, 0, result.stdout)
        for name, args in calls:
            if name == 'codesign' and '--sign' in args:
                self.assertEqual(args[args.index('--sign') + 1], identity)
                self.assertIn('--timestamp', args)
                if not args[-1].endswith('.dmg'):
                    self.assertIn('runtime', args)

    def assert_no_dmg(self, mode, message=None):
        _, result, calls = self.run_lane(mode)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(n == 'hdiutil' for n, _ in calls))
        if message:
            self.assertIn(message, result.stdout)

    def test_bad_pin_stops_packaging(self):
        self.assert_no_dmg('bad-pin', 'Archive Info.plist helper pin mismatch')

    def test_coverage_stops_packaging(self):
        self.assert_no_dmg('coverage', '__LLVM_COV found')

    def test_failed_build_stops_packaging(self):
        self.assert_no_dmg('build-failure', 'Measuring osaurus-ts')

    def test_invalid_signature_stops_packaging(self):
        self.assert_no_dmg('sign-failure', 'osaurus-plugin-host bytes:')


if __name__ == '__main__':
    (ROOT / 'build/t10').mkdir(parents=True, exist_ok=True)
    unittest.main(verbosity=2)
