import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from deliver_draft import android_variants, validate_universal_badging


class UniversalDeliveryTest(unittest.TestCase):
    def test_default_delivery_retains_all_three_separate_apks(self):
        self.assertEqual(android_variants(), [('PREVIEW', 'arm64', 'arm64-v8a'),
            ('ARMV7', 'armv7', 'armeabi-v7a'), ('X64', 'x64', 'x86_64')])
        self.assertEqual(android_variants(True), [('PREVIEW', 'universal', None)])

    def test_universal_requires_every_supported_abi_once(self):
        validate_universal_badging("package: name='example'\nnative-code: 'x86_64' 'armeabi-v7a' 'arm64-v8a'\n")
        for line in ['', "native-code: 'arm64-v8a'", "native-code: 'arm64-v8a' 'arm64-v8a' 'x86_64'",
                     "native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64' 'other'"]:
            with self.subTest(line=line), self.assertRaises(ValueError):
                validate_universal_badging(line)
