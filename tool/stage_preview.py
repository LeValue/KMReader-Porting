#!/usr/bin/env python3
"""Stage a signed APK using the supported Git data API, without changing a ref.

Actions uploads it to the release only after CI, hash and certificate checks.
The signing key never leaves the build machine. No APK is committed to a branch.
"""
import argparse
import base64
import hashlib
import gzip
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('apk', type=Path)
    parser.add_argument('--repo', default='LeValue/KMReader-Porting')
    args = parser.parse_args()
    data = args.apk.read_bytes()
    if len(data) >= 100 * 1024 * 1024:
        raise SystemExit('APK exceeds the Git blob API limit; do not split or commit it.')
    digest = hashlib.sha256(data).hexdigest()
    packed = gzip.compress(data, mtime=0)
    git_hash = hashlib.sha1(b'blob ' + str(len(packed)).encode() + b'\0' + packed).hexdigest()
    with tempfile.TemporaryDirectory(prefix='kmreader-preview-') as temporary:
        request = Path(temporary) / 'blob.json'
        request.write_text(json.dumps({'encoding': 'base64', 'content': base64.b64encode(packed).decode('ascii')}))
        result = subprocess.run(['gh', 'api', '--method', 'POST', f'repos/{args.repo}/git/blobs', '--input', str(request)], capture_output=True, text=True)
        if result.returncode:
            raise SystemExit(result.stderr[:2000])
        uploaded = json.loads(result.stdout)
        if uploaded['sha'] != git_hash:
            raise SystemExit('GitHub returned an unexpected blob hash')
    print(json.dumps({'git_blob': git_hash, 'sha256': digest, 'bytes': len(data)}))


if __name__ == '__main__':
    main()
