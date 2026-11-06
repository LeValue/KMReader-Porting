import base64
import io
import tempfile
import unittest
from pathlib import Path
from PIL import Image

from tool.kindle_personal.cover import allowed_cover_url, extract_cover, thumbnail
from tool.kindle_personal.probe_fixtures import synthetic_progressive_kfx
from tool.kindle_personal.range_source import FileRangeSource


class CoverTest(unittest.TestCase):
    def test_cover_and_page_metadata_do_not_decode_reading_sections(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "synthetic.kfx"
            path.write_bytes(synthetic_progressive_kfx(cover=True))
            source = FileRangeSource(path)
            try:
                result = extract_cover([source])
                with Image.open(io.BytesIO(base64.b64decode(result["image"]))) as image:
                    self.assertEqual(image.size, (480, 720))
                self.assertGreater(result["pages"], 1)
                self.assertTrue(result["estimated"])
                self.assertLess(source.bytes_received, path.stat().st_size // 2)
            finally:
                source.close()

    def test_scoped_loopback_and_content_hosts_only(self):
        valid = "http://127.0.0.1:54321/kindle-cover/" + "a" * 32 + "/0"
        self.assertTrue(allowed_cover_url(valid))
        for value in [
            valid.replace("127.0.0.1", "localhost"),
            valid + "?url=http://other",
            valid.replace(":54321", ":80"),
            "http://169.254.169.254/secret",
            "https://amazon.com.evil.invalid/file",
            "file:///tmp/book",
        ]:
            self.assertFalse(allowed_cover_url(value))

    def test_thumbnail_preserves_transparent_image_on_white(self):
        raw = io.BytesIO()
        Image.new("RGBA", (120, 180), (0, 0, 0, 0)).save(raw, "PNG")
        with Image.open(io.BytesIO(thumbnail(raw.getvalue()))) as result:
            self.assertEqual(result.mode, "RGB")
            self.assertEqual(result.getpixel((0, 0)), (255, 255, 255))
