#!/usr/bin/env python3
"""Check one version across Flutter, the app and the exact signed APK."""
import argparse
import os
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--github-env', action='store_true')
    parser.add_argument('--apk-badging', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    match = re.search(r'^version: (\d+\.\d+\.\d+)\+([1-9]\d*)$',
                      (root / 'pubspec.yaml').read_text(), re.M)
    if not match:
        raise SystemExit('Expected a versioned Flutter preview')
    version, build = match.groups()
    dart = (root / 'lib/core/app_version.dart').read_text()
    if (f"const appVersion = '{version}';" not in dart or
            f'const appBuildNumber = {build};' not in dart):
        raise SystemExit('Flutter and application versions disagree')
    tag = f'v{version}-preview.1'
    if not (root / 'docs/releases' / f'{tag}.md').is_file():
        raise SystemExit('Missing release notes for ' + tag)
    if args.apk_badging:
        badging = args.apk_badging.read_text()
        package = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging, re.M)
        if not package or package.groups() != ('dev.levalue.kmreader.preview', build, version):
            raise SystemExit('APK identity/version does not match this source')
        if 'application-debuggable' in badging:
            raise SystemExit('Publish an optimized, non-debuggable APK')
    values = {'RELEASE_VERSION': version, 'RELEASE_BUILD': build, 'RELEASE_TAG': tag,
              'APK_NAME': f'KMReader-{version}-android-preview.apk',
              'WINDOWS_NAME': f'KMReader-{version}-windows-x64-preview.zip'}
    if args.github_env:
        with Path(os.environ['GITHUB_ENV']).open('a') as output:
            for key, value in values.items():
                output.write(f'{key}={value}\n')
    print(f'KMReader {version} build {build}: {tag}')


if __name__ == '__main__':
    main()
