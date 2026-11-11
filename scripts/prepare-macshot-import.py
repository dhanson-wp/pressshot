#!/usr/bin/env python3
"""Prepare a source-only MacShot snapshot for squash-subtree import.

Run against a separate upstream Git checkout. Doesn't change its worktree.
The resulting commit has no upstream parents: full upstream history stays upstream.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

EXCLUDE_PREFIXES = ('website/', 'assets/', 'macshot.xcodeproj/xcuserdata/')

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('upstream_checkout', type=Path)
parser.add_argument('revision')
args = parser.parse_args()

def git(*argv, env=None, data=None):
    return subprocess.check_output(['git', '-C', str(args.upstream_checkout), *argv],
                                   env=env, input=data).decode().strip()

revision = git('rev-parse', '--verify', args.revision + '^{commit}')
with tempfile.TemporaryDirectory(prefix='pressshot-import-') as scratch:
    env = dict(os.environ, GIT_INDEX_FILE=str(Path(scratch) / 'index'))
    git('read-tree', revision, env=env)
    paths = git('ls-tree', '-r', '--name-only', revision).splitlines()
    removed = [p for p in paths if p.startswith(EXCLUDE_PREFIXES)]
    git('update-index', '--force-remove', '--', *removed, env=env)
    tree = git('write-tree', env=env)
    message = ('Prepare reviewed MacShot source snapshot\n\n'
               f'Upstream-Commit: {revision}\n'
               'Filter: website/, assets/, macshot.xcodeproj/xcuserdata/\n'
               'Preserve native source, shared project, tests, license, and guidance.\n')
    commit = git('commit-tree', tree, data=message.encode())
    git('update-ref', 'refs/heads/pressshot-import-source', commit)
    print(f'Upstream: {revision}\nPrepared source: {commit}\nExcluded paths: {len(removed)}')
    for path in removed:
        print(f'  {path}')
