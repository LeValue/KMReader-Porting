#!/usr/bin/env python3
"""Check one version across Flutter, the app and the exact signed APK."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import zipfile


def read_version(root):
    match = re.search(r'^version: (\d+\.\d+\.\d+)\+([1-9]\d*)$',
                      (root / 'pubspec.yaml').read_text(), re.M)
    if not match:
        raise SystemExit('Expected a versioned Flutter build')
    version, build = match.groups()
    dart = (root / 'lib/core/app_version.dart').read_text()
    if (f"const appVersion = '{version}';" not in dart or
            f'const appBuildNumber = {build};' not in dart):
        raise SystemExit('Flutter and application versions disagree')
    return version, build


def validate_provenance(metadata, source, version, build):
    if (not isinstance(metadata, dict) or metadata.get('source') != source or
            metadata.get('version') != version or type(metadata.get('build')) is not int or
            metadata['build'] != int(build)):
        raise ValueError('Build provenance does not match the verified source/version')


def apk_provenance(path):
    try:
        with zipfile.ZipFile(path) as archive:
            return json.loads(archive.read('assets/flutter_assets/assets/build/source.json'))
    except (KeyError, ValueError, zipfile.BadZipFile) as error:
        raise ValueError('Missing or invalid APK build provenance') from error


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apk-badging', type=Path)
    parser.add_argument('--abi', choices=['arm64-v8a', 'armeabi-v7a', 'x86_64'])
    parser.add_argument('--apk', type=Path)
    parser.add_argument('--source')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    version, build = read_version(root)
    if args.apk:
        source = args.source or subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
        validate_provenance(apk_provenance(args.apk), source, version, build)
    tag = f'v{version}'
    if not (root / 'docs/releases' / f'{tag}.md').is_file():
        raise SystemExit('Missing release notes for ' + tag)
    if args.apk_badging:
        badging = args.apk_badging.read_text()
        package = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging, re.M)
        if not package or package.groups() != ('dev.levalue.kmreader.preview', build, version):
            raise SystemExit('APK identity/version does not match this source')
        if 'application-debuggable' in badging:
            raise SystemExit('Publish an optimized, non-debuggable APK')
        if args.abi:
            native = re.search(r'^native-code: (.+)$', badging, re.M)
            if not native or re.findall(r"'([^']+)'", native.group(1)) != [args.abi]:
                raise SystemExit('Unexpected APK architecture')
    print(f'KMReader {version} build {build}: {tag}')


if __name__ == '__main__':
    main()
