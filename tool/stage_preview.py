#!/usr/bin/env python3
"""Stage a signed APK using the supported Git data API, without changing a ref.

Actions uploads it to the release only after CI, hash and certificate checks.
The signing key never leaves the build machine. No APK is committed to a branch.
"""
import argparse
import base64
import hashlib
import lzma
import json
from pathlib import Path
import subprocess
import tempfile

from preview_metadata import apk_provenance, read_version, validate_provenance


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('apk', type=Path)
    parser.add_argument('--repo', default='LeValue/KMReader-Porting')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, text=True).strip():
        raise SystemExit('Commit source changes before staging a verified preview')
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    version, build = read_version(root)
    validate_provenance(apk_provenance(args.apk), source, version, build)
    data = args.apk.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    packed = lzma.compress(data, preset=6)
    encoded = base64.b64encode(packed).decode('ascii')
    # GitHub counts the encoded JSON request too, not just the stored blob.
    if len(encoded) >= 48_000_000:
        raise SystemExit('Encoded APK exceeds the Git blob request budget; do not split or commit it.')
    git_hash = hashlib.sha1(b'blob ' + str(len(packed)).encode() + b'\0' + packed).hexdigest()
    with tempfile.TemporaryDirectory(prefix='kmreader-preview-') as temporary:
        request = Path(temporary) / 'blob.json'
        request.write_text(json.dumps({'encoding': 'base64', 'content': encoded}))
        result = subprocess.run(['gh', 'api', '--method', 'POST', f'repos/{args.repo}/git/blobs', '--input', str(request)], capture_output=True, text=True)
        if result.returncode:
            raise SystemExit(result.stderr[:2000])
        uploaded = json.loads(result.stdout)
        if uploaded['sha'] != git_hash:
            raise SystemExit('GitHub returned an unexpected blob hash')
    print(json.dumps({'source': source, 'git_blob': git_hash, 'sha256': digest, 'bytes': len(data), 'compression': 'xz', 'compressed_bytes': len(packed)}))


if __name__ == '__main__':
    main()
