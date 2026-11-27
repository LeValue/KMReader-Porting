#!/usr/bin/env python3
"""Transfer verified split APKs to a temporary draft for local signing."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from preview_metadata import apk_provenance, read_version, validate_provenance

ABIS = ('arm64', 'armv7', 'x64')


def verify_split_run(repository, run_id):
    if not re.fullmatch(r'[1-9][0-9]*', run_id):
        raise ValueError('A completed production run is required')
    run = json.loads(subprocess.check_output([
        'gh', 'api', f'repos/{repository}/actions/runs/{run_id}',
    ]))
    source = run.get('head_sha', '')
    if (run.get('status') != 'completed' or run.get('conclusion') != 'success' or
            run.get('event') != 'workflow_dispatch' or run.get('head_branch') != 'main' or
            run.get('path') != '.github/workflows/ci.yml' or
            run.get('repository', {}).get('full_name') != repository or
            not re.fullmatch(r'[0-9a-f]{40}', source)):
        raise ValueError('Expected a successful production build from main')
    return source


def download_split_apks(repository, run_id, directory):
    subprocess.check_call([
        'gh', 'run', 'download', run_id, '--repo', repository,
        '--pattern', 'android-final-*-unsigned', '--dir', str(directory),
    ])
    return {label: directory / f'android-final-{label}-unsigned' / 'app-release.apk'
            for label in ABIS}


def main():
    repository, run_id, tag = (os.environ[name] for name in ('GH_REPO', 'BUILD_RUN', 'DRAFT_TAG'))
    source = verify_split_run(repository, run_id)
    version, build = read_version(Path(__file__).resolve().parent.parent)
    if tag != f'internal-kmreader-{version}-transfer':
        raise ValueError('Expected an internal signing draft for this version')
    draft = json.loads(subprocess.check_output([
        'gh', 'release', 'view', tag, '--repo', repository,
        '--json', 'isDraft,targetCommitish,assets',
    ]))
    if not draft['isDraft'] or draft['targetCommitish'] != source or draft['assets']:
        raise ValueError('Expected an empty internal draft for this exact source')
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        packages = download_split_apks(repository, run_id, directory)
        files, hashes = [], []
        for label, package in packages.items():
            validate_provenance(apk_provenance(package), source, version, build)
            target = directory / f'{label}.apk'
            shutil.move(package, target)
            files.append(target)
            with target.open('rb') as stream:
                hashes.append(f'{hashlib.file_digest(stream, "sha256").hexdigest()}  {target.name}\n')
        manifest = directory / 'SHA256SUMS.txt'
        manifest.write_text(''.join(hashes))
        subprocess.check_call([
            'gh', 'release', 'upload', tag, '--repo', repository,
            *map(str, files), str(manifest),
        ])


if __name__ == '__main__':
    main()
