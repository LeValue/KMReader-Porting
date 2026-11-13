#!/usr/bin/env python3
"""Deliver verified signed APKs and CI Windows binaries to an existing draft only."""
import argparse
import base64
import hashlib
import json
import lzma
import os
from pathlib import Path
import re
import subprocess
import shutil
import zipfile

from preview_metadata import apk_provenance, read_version, validate_provenance

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = {'android', 'windows', 'android_reader_display'}
RUNTIME_PATHS = ['lib', 'assets', 'android', 'windows', 'third_party', 'pubspec.yaml',
                 'pubspec.lock', 'tool/prepare_build_metadata.py', 'tool/preview_metadata.py',
                 'tool/preview-certificate.sha256', 'tool/install_android_ndk.sh',
                 'tool/kindle_personal', 'tool/kindle_android', 'tool/build_kindle_worker.ps1']


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def candidate_tag_matches(version, tag):
    return re.fullmatch(re.escape('v' + version) +
                        r'(?:-(?:epub-)?candidate\.[1-9][0-9]*)?', tag) is not None


def verify():
    repository = os.environ['GH_REPO']
    requested, tag = os.environ['VERIFIED_RUN'], os.environ['DRAFT_TAG']
    if not re.fullmatch(r'[1-9][0-9]*', requested):
        raise ValueError('A completed verification run is required')
    run = api(f'repos/{repository}/actions/runs/{requested}')
    source = run.get('head_sha', '')
    if (run.get('status') != 'completed' or run.get('conclusion') != 'success' or
            not re.fullmatch('[0-9a-f]{40}', source) or
            run.get('head_branch') not in {'main', 'fix/android-epub-recovery'} or
            run.get('event') not in {'push', 'workflow_dispatch'} or
            run.get('path') != '.github/workflows/ci.yml' or
            run.get('repository', {}).get('full_name') != repository):
        raise ValueError('Unrecognized or unsuccessful source verification')
    jobs = api(f'repos/{repository}/actions/runs/{requested}/jobs?per_page=100')
    if jobs['total_count'] > len(jobs['jobs']):
        raise ValueError('Incomplete job listing')
    passed = {j['name'] for j in jobs['jobs'] if j.get('conclusion') == 'success'}
    if not REQUIRED <= passed:
        raise ValueError('All native and release jobs must pass')
    if subprocess.run(['git', 'cat-file', '-e', source + '^{commit}'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        subprocess.check_call(['git', 'fetch', '--no-tags', '--depth=1', 'origin', source])
    subprocess.check_call(['git', 'diff', '--exit-code', source, 'HEAD', '--', *RUNTIME_PATHS])
    version, build = read_version(ROOT)
    if not candidate_tag_matches(version, tag):
        raise ValueError('Only a version-matched candidate draft can receive these files')
    releases = api(f'repos/{repository}/releases?per_page=100')
    release = next((r for r in releases if r['tag_name'] == tag), None)
    if (not release or not release['draft'] or release['assets'] or
            release['target_commitish'] != source):
        raise ValueError('An empty existing draft targeting the verified source is required')
    return repository, requested, source, version, build, release


def android_variants(universal=False):
    return [('PREVIEW', 'universal', None)] if universal else [
        ('PREVIEW', 'arm64', 'arm64-v8a'),
        ('ARMV7', 'armv7', 'armeabi-v7a'), ('X64', 'x64', 'x86_64')]


def validate_universal_badging(badging):
    match = re.search(r'^native-code: (.+)$', badging, re.M)
    abis = re.findall(r"'([^']+)'", match[1]) if match else []
    if len(abis) != 3 or set(abis) != {'arm64-v8a', 'armeabi-v7a', 'x86_64'}:
        raise ValueError('Universal APK must contain exactly all three supported ABIs')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--apk-directory', type=Path, help='Locally signed APKs; all source, signature and CI checks still apply')
    args = parser.parse_args()
    repository, requested, source, version, build, release = verify()
    if args.verify_only:
        print(json.dumps({'verifiedSource': source, 'run': requested, 'draft': release['html_url']}))
        return
    output = ROOT / '.dart_tool/draft-delivery'
    output.mkdir(parents=True, exist_ok=True)
    sdk = Path(os.environ['ANDROID_HOME']) / 'build-tools/36.0.0'
    certificate = (ROOT / 'tool/preview-certificate.sha256').read_text().strip()
    delta_base = None
    if os.environ.get('APK_DELTAS', '').lower() == 'true':
        base_directory = output / 'verified-ci-base'
        subprocess.check_call(['gh', 'run', 'download', requested, '--repo', repository,
                               '--name', 'android-release-unsigned', '--dir', str(base_directory)])
        delta_base = base_directory / 'app-release.apk'
        validate_provenance(apk_provenance(delta_base), source, version, build)
    files = []
    for prefix, label, abi in android_variants(os.environ.get('ANDROID_UNIVERSAL', '').lower() == 'true'):
        target = output / f'KMReader-{version}-android-{label}-preview.apk'
        if args.apk_directory:
            local = args.apk_directory / target.name
            if not local.is_file():
                raise ValueError('Missing locally signed APK: ' + label)
            shutil.copyfile(local, target)
        else:
            blob_id, expected = os.environ[prefix + '_BLOB'], os.environ[prefix + '_SHA256']
            if not re.fullmatch('[0-9a-f]{40}', blob_id) or not re.fullmatch('[0-9a-f]{64}', expected):
                raise ValueError('A verified signed APK is required: ' + label)
            blob = api(f'repos/{repository}/git/blobs/{blob_id}')
            if blob['encoding'] != 'base64':
                raise ValueError('Unsupported blob encoding')
            packed = base64.b64decode(blob['content'])
            if hashlib.sha1(b'blob ' + str(len(packed)).encode() + b'\0' + packed).hexdigest() != blob_id:
                raise ValueError('Git object hash mismatch')
            if delta_base is not None:
                from apk_delta import apply_delta
                content = apply_delta(delta_base, packed, expected)
            else:
                content = lzma.decompress(packed)
            if hashlib.sha256(content).hexdigest() != expected:
                raise ValueError('APK checksum mismatch')
            target.write_bytes(content)
        validate_provenance(apk_provenance(target), source, version, build)
        signature = subprocess.check_output([str(sdk / 'apksigner'), 'verify', '--verbose', '--print-certs', str(target)], text=True)
        if 'Signer #1 certificate SHA-256 digest: ' + certificate not in signature:
            raise ValueError('Unexpected signing certificate')
        subprocess.check_call([str(sdk / 'zipalign'), '-c', '-P', '16', '4', str(target)])
        badging = output / (label + '-badging.txt')
        badging.write_text(subprocess.check_output([str(sdk / 'aapt2'), 'dump', 'badging', str(target)], text=True))
        metadata_command = ['python3', str(ROOT / 'tool/preview_metadata.py'), '--apk-badging', str(badging),
                            '--apk', str(target), '--source', source]
        if abi:
            metadata_command.extend(['--abi', abi])
        else:
            validate_universal_badging(badging.read_text())
        subprocess.check_call(metadata_command)
        with zipfile.ZipFile(target) as archive:
            if archive.read('assets/flutter_assets/assets/epub/reader.js') != (ROOT / 'assets/epub/reader.js').read_bytes():
                raise ValueError('Unexpected Android reader assets')
        files.append(target)
        print('Verified signed ' + label + ' APK', flush=True)
    bundle = output / 'windows'
    subprocess.check_call(['gh', 'run', 'download', requested, '--repo', repository, '--name', 'windows', '--dir', str(bundle)])
    validate_provenance(json.loads((bundle / 'data/flutter_assets/assets/build/source.json').read_text()), source, version, build)
    for name in ['kmreader.exe', 'flutter_windows.dll', 'data/app.so']:
        if not (bundle / name).is_file():
            raise ValueError('Incomplete Windows bundle: ' + name)
    if not (bundle / 'kindle/KMReader-Kindle.exe').is_file() or not list(bundle.glob('KMReader-Kindle-*-source.zip')):
        raise ValueError('Kindle converter or corresponding source missing')
    if not list(bundle.glob('vcruntime140*.dll')):
        raise ValueError('Portable MSVC runtime missing')
    if ((bundle / 'data/flutter_assets/assets/epub/reader.js').read_bytes().replace(b'\r\n', b'\n') !=
            (ROOT / 'assets/epub/reader.js').read_bytes().replace(b'\r\n', b'\n')):
        raise ValueError('Unexpected Windows reader assets')
    windows = output / f'KMReader-{version}-windows-x64-preview.zip'
    with zipfile.ZipFile(windows, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(bundle.rglob('*')):
            if path.is_file():
                archive.write(path, 'KMReader/' + path.relative_to(bundle).as_posix())
    files.append(windows)
    sums = output / 'SHA256SUMS.txt'
    sums.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in files))
    files.append(sums)
    # Recheck immediately before uploading; never overwrite existing assets or
    # change publication state, title, target, tag, or release notes.
    current = api(f'repos/{repository}/releases/{release["id"]}')
    if not current['draft'] or current['assets'] or current['target_commitish'] != source:
        raise ValueError('The draft changed during verification')
    subprocess.check_call(['gh', 'release', 'upload', release['tag_name'], '--repo', repository, *map(str, files)])
    uploaded = api(f'repos/{repository}/releases/{release["id"]}')
    if not uploaded['draft'] or len(uploaded['assets']) != len(files):
        raise ValueError('Unexpected release state after delivery')
    for path in files:
        asset = next(a for a in uploaded['assets'] if a['name'] == path.name)
        if (asset['state'] != 'uploaded' or asset['size'] != path.stat().st_size or
                asset['digest'] != 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()):
            raise ValueError('Uploaded asset verification failed: ' + path.name)
    print('Verified build files delivered; release remains a draft: ' + uploaded['html_url'])


if __name__ == '__main__':
    main()
