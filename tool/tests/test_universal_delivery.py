import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from deliver_draft import android_variants, validate_universal_badging, update_manifest
import tempfile
import hashlib


class UniversalDeliveryTest(unittest.TestCase):
    def test_default_delivery_retains_all_three_separate_apks(self):
        self.assertEqual(android_variants(), [('PREVIEW', 'arm64', 'arm64-v8a'),
            ('ARMV7', 'armv7', 'armeabi-v7a'), ('X64', 'x64', 'x86_64')])
        self.assertEqual(android_variants(True), [('PREVIEW', 'universal', None)])

    def test_public_feed_uses_exact_asset_bytes_and_platforms(self):
        with tempfile.TemporaryDirectory() as root:
            apk = Path(root) / 'KMReader-1.0.0-android-universal-preview.apk'
            windows = Path(root) / 'KMReader-1.0.0-windows-x64-preview.zip'
            apk.write_bytes(b'signed APK'); windows.write_bytes(b'Windows bundle')
            feed = update_manifest('LeValue/KMReader-Porting', 'v1.0.0-candidate.5', 'a'*40, '1.0.0', '35', [apk, windows])
            self.assertEqual(feed['build'], 35)
            self.assertEqual(set(feed['packages']), {'android','windows'})
            self.assertEqual(feed['packages']['android']['sha256'], hashlib.sha256(apk.read_bytes()).hexdigest())
            self.assertEqual(feed['packages']['windows']['size'], windows.stat().st_size)
            self.assertTrue(feed['packages']['android']['url'].endswith('/v1.0.0-candidate.5/'+apk.name))
            arm = Path(root) / 'KMReader-1.0.0-android-armv7-preview.apk'; arm.write_bytes(b'ARM32')
            self.assertEqual(set(update_manifest('x/y','tag','a'*40,'1.0.0',35,[arm])['packages']), {'android-armeabi-v7a'})

    def test_universal_requires_every_supported_abi_once(self):
        validate_universal_badging("package: name='example'\nnative-code: 'x86_64' 'armeabi-v7a' 'arm64-v8a'\n")
        for line in ['', "native-code: 'arm64-v8a'", "native-code: 'arm64-v8a' 'arm64-v8a' 'x86_64'",
                     "native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64' 'other'"]:
            with self.subTest(line=line), self.assertRaises(ValueError):
                validate_universal_badging(line)
