#!/usr/bin/env python3
"""Check release refusal paths without contacting GitHub, signing or notarizing."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).with_name('release.sh')
GIT = shutil.which('git')


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='facienda-release-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        shutil.copyfile(SOURCE, self.root / 'scripts/release.sh')
        notes = self.root / 'docs/releases/1.0.0.md'
        notes.parent.mkdir(parents=True)
        notes.write_text('Test release\n')
        self.git('init', '-q', '-b', 'main')
        self.git('add', '.')
        self.git('-c', 'user.name=Release Test', '-c', 'user.email=test@example.org',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Fixture')
        self.commit = self.git('rev-parse', 'HEAD').strip()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'commands'

    def git(self, *args):
        return subprocess.check_output([GIT, '-C', str(self.root), *args], text=True)

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)

    def run_release(self, *, sha=None, api_status=0, tag='', git_status=0, dry=False):
        self.stub('gh', f'printf "%s\\n" {shlex.quote(sha or self.commit)}; exit {api_status}')
        self.stub('git', f'''if test "$1" = ls-remote; then
    printf '%s\\n' {shlex.quote(tag)}
    exit {git_status}
fi
exec {shlex.quote(GIT)} "$@"''')
        # The first build command is a hard stop. No Apple or publishing commands can be reached.
        self.stub('xcodegen', f'echo build >> {shlex.quote(str(self.log))}; exit 73')
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        result = subprocess.run(['bash', str(self.root / 'scripts/release.sh'), '--version', '1.0.0',
                                 *(['--dry-run'] if dry else [])], env=env, capture_output=True, text=True, timeout=20)
        return result

    def test_refuses_unpublished_source_before_build(self):
        result = self.run_release(api_status=1)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Publish the reviewed source first', result.stderr)
        self.assertFalse(self.log.exists())

    def test_refuses_wrong_source_before_build(self):
        result = self.run_release(sha='0' * 40)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(self.log.exists())

    def test_does_not_treat_network_failure_as_missing_tag(self):
        result = self.run_release(git_status=128)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Could not check the release tag', result.stderr)
        self.assertFalse(self.log.exists())

    def test_refuses_existing_public_tag(self):
        result = self.run_release(tag='0' * 40 + '\trefs/tags/v1.0.0')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('refusing to reuse its tag', result.stderr)
        self.assertFalse(self.log.exists())

    def test_published_source_can_reach_build(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(self.log.read_text(), 'build\n')

    def test_dry_run_can_build_without_publishing_source(self):
        result = self.run_release(api_status=1, git_status=128, dry=True)
        self.assertEqual(result.returncode, 73, result.stderr)

    def test_publication_targets_the_built_commit(self):
        # Run the actual publication command with a recording function, without running a release build.
        command, = [line for line in SOURCE.read_text().splitlines() if line.startswith('gh release create ')]
        setup = f'''set -eu
version=1.0.0
repository=example/repo
commit={self.commit}
notes='notes with spaces.md'
dmg='release with spaces.dmg'
output='output with spaces'
gh() {{ printf '%s\\n' "$@"; }}
'''
        args = subprocess.check_output(['bash'], input=setup + command, text=True).splitlines()
        self.assertIn('--target', args)
        self.assertEqual(args[args.index('--target') + 1], self.commit)
        self.assertIn('release with spaces.dmg', args)


if __name__ == '__main__':
    unittest.main()
