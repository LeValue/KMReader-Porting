"""Real offline conversion of our own KFX; no Amazon fixtures or credentials."""

import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from tool.kindle_personal.cli import main
from tool.kindle_personal.common import KindleError, file_hash, write_json
from tool.kindle_personal.prepare import inspect_file, prepare_download
from tool.kindle_personal.selfcheck import synthetic_kfx


class KfxPreparationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="kindle kfx test ")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "0000-document.azw"
        self.source.write_bytes(synthetic_kfx())
        notes = self.directory / "0001-notes.mbpV2"
        notes.write_bytes(b'{"notes":[]}')
        write_json(
            self.directory / "receipt.json",
            {
                "download_state": "complete",
                "resources": [
                    {
                        "file": p.name,
                        "bytes": p.stat().st_size,
                        "sha256": file_hash(p),
                        "type": kind,
                    }
                    for p, kind in (
                        (self.source, "KINDLE_MAIN_BASE"),
                        (notes, "KINDLE_USER_ANOT"),
                    )
                ],
            },
        )

    def test_cont_is_kfx_even_when_amazon_names_it_azw(self):
        self.assertEqual(self.source.read_bytes()[:4], b"CONT")
        self.assertEqual(inspect_file(self.source)["format"], "kfx")
        with patch("tool.kindle_personal.prepare.subprocess.run") as process:
            result = prepare_download(self.directory, convert=False)
        process.assert_not_called()
        self.assertEqual(result["state"], "needs_conversion")

    def test_old_calibre_missing_download_converts_and_reopens_offline(self):
        write_json(
            self.directory / "preparation.json",
            {
                "state": "needs_conversion",
                "format": "unknown",
                "reason": "calibre_missing",
            },
        )
        with patch(
            "tool.kindle_personal.prepare.find_converter",
            side_effect=AssertionError("Calibre must not be required"),
        ):
            result = prepare_download(self.directory, convert=True)
        self.assertEqual(result["state"], "importable")
        self.assertFalse(result["opened_in_kmreader"])
        output = self.directory / result["file"]
        self.assertTrue(inspect_file(output)["importable"])
        with zipfile.ZipFile(output) as archive:
            self.assertTrue(
                any(
                    b"Questo documento sintetico" in archive.read(name)
                    for name in archive.namelist()
                    if name.endswith(".xhtml")
                )
            )
        with patch(
            "tool.kindle_personal.prepare.subprocess.run",
            side_effect=AssertionError("Cached file must be reused"),
        ):
            self.assertEqual(prepare_download(self.directory, convert=True), result)

    def test_worker_dispatch_does_not_open_a_session_vault_or_lock(self):
        with (
            patch(
                "tool.kindle_personal.cli.WindowsVault",
                side_effect=AssertionError("No vault"),
            ),
            patch(
                "tool.kindle_personal.cli.exclusive",
                side_effect=AssertionError("No lock"),
            ),
            patch(
                "tool.kindle_personal.kfx_conversion.convert_kfx", return_value=0
            ) as worker,
        ):
            output = self.directory / "output.epub"
            self.assertEqual(main(["convert-kfx", str(self.source), str(output)]), 0)
        worker.assert_called_once_with(self.source.resolve(), output.resolve())

    def test_worker_success_is_not_enough_without_a_valid_epub(self):
        def invalid_output(arguments, **kwargs):
            self.assertFalse(kwargs["shell"])
            self.assertEqual(arguments[-3], "convert-kfx")
            with zipfile.ZipFile(arguments[-2]) as archive:
                self.assertEqual(
                    set(archive.namelist()), {"0000-document.azw", "0001-notes.mbpV2"}
                )
            Path(arguments[-1]).write_bytes(b"not an EPUB")
            return subprocess.CompletedProcess(arguments, 0)

        with patch(
            "tool.kindle_personal.prepare.subprocess.run", side_effect=invalid_output
        ):
            result = prepare_download(self.directory, convert=True)
        self.assertEqual(result["reason"], "kfx_conversion_unsupported")
        self.assertEqual(result["state"], "needs_conversion")
        self.assertFalse((self.directory / "ready.epub").exists())

    def test_protected_and_missing_converter_are_explicit(self):
        for code, reason in ((4, "kfx_protected"), (6, "kfx_converter_missing")):
            with (
                self.subTest(code=code),
                patch(
                    "tool.kindle_personal.prepare.subprocess.run",
                    return_value=subprocess.CompletedProcess([], code),
                ),
            ):
                self.assertEqual(
                    prepare_download(self.directory, convert=True)["reason"], reason
                )

    def test_conversion_timeout_does_not_publish_a_file(self):
        with patch(
            "tool.kindle_personal.prepare.subprocess.run",
            side_effect=subprocess.TimeoutExpired("worker", 600),
        ):
            result = prepare_download(self.directory, convert=True)
        self.assertEqual(result["reason"], "conversion_timeout")
        self.assertFalse((self.directory / "ready.epub").exists())
        self.assertEqual(list(self.directory.glob(".prepare-*")), [])

    def test_changed_source_is_rejected_before_conversion(self):
        self.source.write_bytes(b"CONTtampered")
        with patch("tool.kindle_personal.prepare.subprocess.run") as process:
            with self.assertRaises(KindleError) as caught:
                prepare_download(self.directory, convert=True)
        process.assert_not_called()
        self.assertEqual(caught.exception.code, "local_integrity")


if __name__ == "__main__":
    unittest.main()
