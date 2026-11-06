import hashlib
import json
import lzma
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

from tool.apk_delta import MAGIC, apply_delta, make_delta


class ApkTransportTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name) / 'ci.apk'
        self.target = Path(self.temporary.name) / 'signed.apk'
        shared = bytes(range(256)) * 1000
        with zipfile.ZipFile(self.base, 'w') as archive:
            archive.writestr('assets/model', shared)
            archive.writestr('lib/arm64/library.so', b'old code')
            archive.writestr('lib/armv7/library.so', b'other architecture')
        with zipfile.ZipFile(self.target, 'w') as archive:
            info = zipfile.ZipInfo('assets/model', (2026, 11, 6, 12, 0, 0))
            info.extra = b'\x01\x00\x04\x00\x00\x00\x00\x00'
            archive.writestr(info, shared)
            archive.writestr('lib/arm64/library.so', b'new code')
        with self.target.open('ab') as file:
            file.write(b'EXACT SIGNATURE BYTES')
        self.sha = hashlib.sha256(self.target.read_bytes()).hexdigest()

    def test_transport_preserves_exact_headers_alignment_payloads_and_signature(self):
        patch = make_delta(self.base, self.target)
        self.assertLess(len(patch), 3000)
        self.assertEqual(apply_delta(self.base, patch, self.sha), self.target.read_bytes())

    def test_different_ci_base_or_expected_signed_hash_is_rejected(self):
        patch = make_delta(self.base, self.target)
        with self.assertRaises(ValueError):
            apply_delta(self.base, patch, '0' * 64)
        self.base.write_bytes(b'wrong CI artifact')
        with self.assertRaises(ValueError):
            apply_delta(self.base, patch, self.sha)

    def test_out_of_bounds_copy_is_rejected_before_reconstruction(self):
        header = {'schema': 1, 'base_sha256': hashlib.sha256(self.base.read_bytes()).hexdigest(),
                  'result_sha256': self.sha, 'size': self.target.stat().st_size,
                  'segments': [['base', -1, 100]]}
        raw = json.dumps(header).encode()
        patch = lzma.compress(MAGIC + struct.pack('<I',len(raw)) + raw)
        with self.assertRaises(ValueError):
            apply_delta(self.base, patch, self.sha)
