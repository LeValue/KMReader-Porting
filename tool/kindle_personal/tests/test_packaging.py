"""Keep corresponding-source delivery complete without exposing user data."""

import tempfile
import unittest
import zipfile
from pathlib import Path

from tool.package_kindle_prototype import source_bundle


class SourcePackageTest(unittest.TestCase):
    def test_source_archive_includes_converter_and_build_files_but_no_user_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository, dependency, output = root / "repo", root / "kfx", root / "out"
            files = {
                "tool/kindle_personal/cli.py": "# own source\n",
                "tool/kindle_personal/requirements.txt": "kfxlib\n",
                "tool/kindle_personal_cli.py": "# entry point\n",
                "tool/package_kindle_prototype.py": "# build tool\n",
                ".github/workflows/ci.yml": "# active app workflow\n",
                "tool/build_kindle_worker.ps1": "# shared build entry\n",
                "tool/kindle_android/kmreader_kfx.py": "# android entry\n",
                "android/app/build.gradle.kts": "// native packaging\n",
                "archive/kindle-prototype/kindle-prototype.yml": "# archived workflow\n",
                "archive/kindle-prototype/README.md": "# historical guide\n",
                "assets/kindle/NOTICE.md": "# worker notice\n",
                "assets/kindle/COPYING": "GPL test notice\n",
                "LICENSE": "MIT test notice\n",
                "tool/kindle_personal/session.dpapi": "PRIVATE_SESSION",
                "tool/kindle_personal/receipt.json": "PRIVATE_RECEIPT",
                "tool/kindle_personal/private.epub": "PRIVATE_BOOK",
                "artifacts/private/book.azw": "PRIVATE_CONTENT",
            }
            for name, value in files.items():
                path = repository / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(value.encode("utf-8"))
            dependency.mkdir()
            (dependency / "COPYING").write_bytes(b"GPL test notice\n")
            (dependency / "pyproject.toml").write_bytes(b"# upstream build config\n")
            (dependency / "parser.py").write_bytes(b"# upstream source\n")
            output.mkdir()
            archive = source_bundle(
                repository,
                dependency,
                output,
                "test",
                {
                    "source": "test",
                    "dependencies": {"kfxlib": "20260827", "pyinstaller": "6.22.3"},
                },
            )
            with zipfile.ZipFile(archive) as bundle:
                self.assertEqual(bundle.testzip(), None)
                self.assertEqual(bundle.read("LICENSE"), b"GPL test notice\n")
                self.assertEqual(bundle.read("MIT-LICENSE"), b"MIT test notice\n")
                self.assertEqual(
                    bundle.read("vendor/kfxlib/parser.py"), b"# upstream source\n"
                )
                self.assertEqual(
                    bundle.read("requirements-build.txt"),
                    b"./vendor/kfxlib\npyinstaller==6.22.3\n",
                )
                self.assertIn("REBUILD.md", bundle.namelist())
                for name in (
                    ".github/workflows/ci.yml",
                    "tool/build_kindle_worker.ps1",
                    "tool/kindle_android/kmreader_kfx.py",
                    "android/app/build.gradle.kts",
                    "archive/kindle-prototype/kindle-prototype.yml",
                    "archive/kindle-prototype/README.md",
                    "assets/kindle/NOTICE.md",
                    "assets/kindle/COPYING",
                ):
                    self.assertEqual(bundle.read(name), files[name].encode("utf-8"))
                self.assertNotIn(".github/workflows/kindle-prototype.yml", bundle.namelist())
                self.assertFalse(
                    any(b"PRIVATE_" in bundle.read(name) for name in bundle.namelist())
                )


if __name__ == "__main__":
    unittest.main()
