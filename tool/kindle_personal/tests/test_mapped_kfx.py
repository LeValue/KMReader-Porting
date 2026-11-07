"""Only generated publication text; no user book or account material."""

import io
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from lxml import etree

from tool.kindle_personal.mapped_kfx import mapped_epub
from tool.kindle_personal.probe_fixtures import synthetic_progressive_kfx
from tool.kindle_personal.kfx_progressive import quiet_library


class MappedKfxTest(unittest.TestCase):
    def test_mapping_does_not_change_text_or_dom_structure(self):
        from kfxlib import YJ_Book

        quiet_library()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fixture.kfx"
            path.write_bytes(synthetic_progressive_kfx(sections=3))
            reference = YJ_Book(str(path)).convert_to_epub()
            mapped = mapped_epub(path)
            with (
                zipfile.ZipFile(io.BytesIO(reference)) as before,
                zipfile.ZipFile(io.BytesIO(mapped)) as after,
            ):
                metadata = json.loads(after.read("META-INF/kmreader-kindle.json"))
                self.assertEqual(metadata["position_units"], "unicode_scalars")
                self.assertGreaterEqual(len(metadata["entries"]), 3)
                for name in before.namelist():
                    if not name.endswith((".xhtml", ".html")):
                        # Upstream creates a fresh publication UUID/date per run.
                        if not name.endswith((".opf", ".ncx")):
                            self.assertEqual(before.read(name), after.read(name))
                        continue
                    old = etree.fromstring(before.read(name))
                    new = etree.fromstring(after.read(name))
                    self.assertEqual("".join(old.itertext()), "".join(new.itertext()))
                    self.assertEqual(
                        [node.tag for node in old.iter()],
                        [node.tag for node in new.iter()],
                    )
                for entry in metadata["entries"]:
                    doc = etree.fromstring(after.read(entry["path"]))
                    element = doc.xpath("//*[@id=$id]", id=entry["id"])[0]
                    text = "".join(element.itertext())
                    self.assertIn("😀", text)
                    self.assertEqual(len(text), entry["length"])
                    self.assertGreater(
                        len(text.encode("utf-16-le")) // 2, entry["length"]
                    )
                    self.assertEqual(
                        int(element.get("data-kmreader-kindle-position")),
                        entry["position"],
                    )

    def test_android_worker_prepares_same_faithful_mapped_publication(self):
        import sys

        # Android's generated package is rooted at kindle_personal.
        sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
        from tool.kindle_android.kmreader_kfx import prepare

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "base.azw").write_bytes(synthetic_progressive_kfx(sections=2))
            (root / "receipt.json").write_text(
                json.dumps(
                    {"resources": [{"type": "KINDLE_MAIN_BASE", "file": "base.azw"}]}
                )
            )
            result = json.loads(prepare(tmp))
            self.assertTrue(result["ok"], result)
            self.assertTrue(result["preparation"]["kindle_locator_map"])
            with zipfile.ZipFile(root / "ready.epub") as book:
                self.assertGreater(
                    len(
                        json.loads(book.read("META-INF/kmreader-kindle.json"))[
                            "entries"
                        ]
                    ),
                    0,
                )
            self.assertFalse((root / "book.kfx-zip").exists())
