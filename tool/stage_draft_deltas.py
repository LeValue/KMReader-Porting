"""Stage byte-exact signed APKs through bounded CI-based transport blobs.

No signing key leaves this machine and no binary is committed to a branch.
The receiving delivery job repeats source, signature and hash verification.
"""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from apk_delta import apply_delta, make_delta
from deliver_draft import verify
from preview_metadata import apk_provenance, validate_provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip():
        raise ValueError('Commit delivery changes before staging transport blobs')
    repository, run, source, version, build, _ = verify()
    root = Path('.dart_tool/draft-deltas')
    root.mkdir(parents=True, exist_ok=True)
    base_dir = root / run
    base = base_dir / 'app-release.apk'
    if not base.exists():
        subprocess.check_call(['gh', 'run', 'download', run, '--repo', repository,
                               '--name', 'android-release-unsigned', '--dir', str(base_dir)])
    validate_provenance(apk_provenance(base), source, version, build)
    result = {'verified_run': run, 'source': source, 'apk_deltas': True}
    for label, prefix in [('arm64', 'preview'), ('armv7', 'preview_armv7'), ('x64', 'preview_x64')]:
        file = args.directory / f'KMReader-{version}-android-{label}-preview.apk'
        validate_provenance(apk_provenance(file), source, version, build)
        expected = hashlib.sha256(file.read_bytes()).hexdigest()
        patch = make_delta(base, file)
        if hashlib.sha256(apply_delta(base, patch, expected)).hexdigest() != expected:
            raise ValueError('Local transport verification failed')
        (root / f'{label}.delta.xz').write_bytes(patch)
        encoded = base64.b64encode(patch).decode('ascii')
        if len(encoded) >= 48_000_000:
            raise ValueError('Transport blob exceeds the API request budget')
        git_hash = hashlib.sha1(b'blob ' + str(len(patch)).encode() + b'\0' + patch).hexdigest()
        with tempfile.TemporaryDirectory(prefix='kmreader-delivery-') as temporary:
            request = Path(temporary) / 'blob.json'
            request.write_text(json.dumps({'encoding':'base64', 'content':encoded}))
            response = json.loads(subprocess.check_output([
                'gh','api','--method','POST',f'repos/{repository}/git/blobs','--input',str(request)
            ], text=True))
        if response['sha'] != git_hash:
            raise ValueError('Staged blob hash mismatch')
        result[prefix + '_blob'] = git_hash
        result[prefix + '_sha256'] = expected
        print(json.dumps({'architecture':label,'transport_bytes':len(patch),'signed_bytes':file.stat().st_size}), flush=True)
    args.output.write_text(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
