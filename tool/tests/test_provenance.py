import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from tool.preview_metadata import apk_provenance, validate_provenance


class ProvenanceTest(unittest.TestCase):
    def test_exact_source_and_version_pass(self):
        validate_provenance({'source': 'a' * 40, 'version': '0.6.1', 'build': 8}, 'a' * 40, '0.6.1', 8)

    def test_stale_source_version_build_and_malformed_values_are_rejected(self):
        base = {'source': 'a' * 40, 'version': '0.6.1', 'build': 8}
        for metadata in [{**base, 'source': 'b' * 40}, {**base, 'version': '0.6.0'},
                         {**base, 'build': 7}, {**base, 'build': '8'}, {}, None, []]:
            with self.subTest(metadata=metadata), self.assertRaises(ValueError):
                validate_provenance(metadata, 'a' * 40, '0.6.1', 8)

    def test_apk_requires_embedded_source_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'fixture.apk'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('classes.dex', b'fixture')
            with self.assertRaises(ValueError):
                apk_provenance(path)
            record = {'source': 'a' * 40, 'version': '0.6.1', 'build': 8}
            with zipfile.ZipFile(path, 'a') as archive:
                archive.writestr('assets/flutter_assets/assets/build/source.json', json.dumps(record))
            self.assertEqual(apk_provenance(path), record)
