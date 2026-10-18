#!/usr/bin/env python3
"""Exercise release boundaries without signing, notarization or network access."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).parent
GIT = shutil.which('git')


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='facienda-release-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        for name in ('release.sh', 'release_metadata.py'):
            shutil.copyfile(SCRIPTS / name, self.root / 'scripts' / name)
        notes = self.root / 'docs/releases/1.0.0.md'
        notes.parent.mkdir(parents=True)
        notes.write_text('Test release\n')
        (self.root / 'project.yml').write_text('settings:\n  MARKETING_VERSION: 1.0.0\n')
        (self.root / '.gitignore').write_text('bin/\ncommands\nbuild/\n')
        self.git('init', '-q', '-b', 'main')
        self.git('add', '.')
        self.git('-c', 'user.name=Release Test', '-c', 'user.email=test@example.org',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Fixture')
        self.commit = self.git('rev-parse', 'HEAD').strip()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'commands'
        self.prepared = self.root / 'build' / 'prepared release'
        self.prepared.mkdir(parents=True)
        (self.prepared / 'Facienda.zip').write_bytes(b'fixture archive')
        (self.prepared / 'notes.md').write_text('Test release\n')
        self.record()

    def git(self, *args):
        return subprocess.check_output([GIT, '-C', str(self.root), *args], text=True)

    def record(self, **overrides):
        data = dict(schema=1, commit=self.commit, version='1.0.0', build='20261018153000')
        data.update(overrides)
        data['sha256'] = {name: hashlib.sha256((self.prepared / name).read_bytes()).hexdigest()
                          for name in ('Facienda.zip', 'notes.md')}
        (self.prepared / 'release.json').write_text(json.dumps(data))

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)

    def run_release(self, *args, sha=None, api_status=0, tags='', git_status=0, latest='', download_status=0):
        log = shlex.quote(str(self.log))
        self.stub('gh', f'''echo "gh $*" >> {log}
case "$1 $2" in
    'api repos/jostelzer/facienda/commits/main') printf '%s\\n' {shlex.quote(sha or self.commit)}; exit {api_status} ;;
    'api repos/jostelzer/facienda/releases?per_page=100') printf '%s\\n' {shlex.quote(latest)} ;;
    'release download') exit {download_status} ;;
    *) exit 99 ;;
esac''')
        self.stub('git', f'''if test "$1" = ls-remote; then
    echo remote-tags >> {log}
    printf '%s\\n' {shlex.quote(tags)}
    exit {git_status}
fi
exec {shlex.quote(GIT)} "$@"''')
        # Stop before building or extracting anything; real Apple tools cannot be reached.
        self.stub('xcodegen', f'echo build >> {log}; exit 73')
        self.stub('ditto', f'echo extract >> {log}; exit 74')
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        return subprocess.run(['bash', str(self.root / 'scripts/release.sh'), *args],
                              env=env, capture_output=True, text=True, timeout=20)

    def publish(self, **kwargs):
        return self.run_release('--publish', str(self.prepared), **kwargs)

    def test_default_preparation_is_local(self):
        result = self.run_release(api_status=99, git_status=99)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(self.log.read_text(), 'build\n')

    def test_dry_run_is_now_local(self):
        result = self.run_release('--dry-run', api_status=99, git_status=99)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(self.log.read_text(), 'build\n')

    def test_refuses_development_branch(self):
        self.git('switch', '-qc', 'dev')
        result = self.run_release()
        self.assertIn('Release from main', result.stderr)
        self.assertFalse(self.log.exists())

    def test_refuses_dirty_and_untracked_files(self):
        for name in ('project.yml', 'private.txt'):
            with self.subTest(name=name):
                path = self.root / name
                previous = path.read_text() if path.exists() else None
                path.write_text('uncommitted\n')
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('must be clean', result.stderr)
                self.assertFalse(self.log.exists())
                if previous is None:
                    path.unlink()
                else:
                    path.write_text(previous)

    def test_version_argument_cannot_override_committed_version(self):
        result = self.run_release('--version', '1.1.0')
        self.assertIn('differs from project.yml', result.stderr)
        self.assertFalse(self.log.exists())

    def test_refuses_reused_local_tag(self):
        self.git('tag', 'v1.0.0')
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_refuses_unpublished_or_wrong_main(self):
        for kwargs in (dict(api_status=1), dict(sha='0' * 40)):
            with self.subTest(kwargs=kwargs):
                result = self.publish(**kwargs)
                self.assertIn('Push the reviewed main commit', result.stderr)
                self.assertNotIn('extract', self.log.read_text())

    def test_refuses_network_failure_when_checking_tags(self):
        result = self.publish(git_status=128)
        self.assertIn('Could not check release tags', result.stderr)
        self.assertNotIn('extract', self.log.read_text())

    def test_refuses_existing_public_version(self):
        result = self.publish(tags='0' * 40 + '\trefs/tags/v1.0.0')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('extract', self.log.read_text())

    def test_refuses_changed_prepared_archive_before_network(self):
        (self.prepared / 'Facienda.zip').write_bytes(b'changed')
        result = self.publish()
        self.assertIn('has changed', result.stderr)
        self.assertFalse(self.log.exists())

    def test_refuses_wrong_prepared_commit_before_network(self):
        self.record(commit='0' * 40)
        result = self.publish()
        self.assertIn('does not match', result.stderr)
        self.assertFalse(self.log.exists())

    def test_refuses_notes_not_in_the_commit(self):
        (self.prepared / 'notes.md').write_text('Unreviewed notes\n')
        self.record()
        result = self.publish()
        self.assertIn('notes differ', result.stderr)
        self.assertFalse(self.log.exists())

    def test_feed_download_failure_does_not_start_an_empty_feed(self):
        result = self.publish(latest='v0.9.0', download_status=17)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertNotIn('extract', self.log.read_text())

    def test_publication_reuses_prepared_archive_without_building(self):
        result = self.publish()
        self.assertEqual(result.returncode, 74, result.stderr)
        self.assertIn('extract', self.log.read_text())
        self.assertNotIn('build', self.log.read_text())

    def test_publication_targets_the_built_commit(self):
        command, = [line for line in (SCRIPTS / 'release.sh').read_text().splitlines() if line.startswith('gh release create ')]
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
        self.assertEqual(args[args.index('--target') + 1], self.commit)
        self.assertIn('release with spaces.dmg', args)


if __name__ == '__main__':
    unittest.main()
