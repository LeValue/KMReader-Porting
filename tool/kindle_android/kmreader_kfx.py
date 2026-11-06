"""On-demand Android worker. File conversion only, no sessions or networking."""

import json
import logging
import shutil
import zipfile
from pathlib import Path


def prepare(directory):
    root = Path(directory)
    receipt = json.loads((root / "receipt.json").read_text())
    bases = [
        item for item in receipt["resources"] if item["type"] == "KINDLE_MAIN_BASE"
    ]
    if not bases:
        return json.dumps({"ok": False, "error": {"code": "resource_set_unsupported"}})
    for item in receipt["resources"]:
        if (
            Path(item["file"]).name != item["file"]
            or "/" in item["file"]
            or "\\" in item["file"]
        ):
            raise ValueError()
    from kindle_personal.prepare import inspect_file

    if len(bases) == 1 and not any(
        item["type"] == "KINDLE_MAIN_ATTACHABLE" for item in receipt["resources"]
    ):
        source = root / bases[0]["file"]
        inspected = inspect_file(source)
        if inspected["importable"]:
            name = "ready." + inspected["format"]
            shutil.copyfile(source, root / name)
            return json.dumps(
                {
                    "ok": True,
                    "preparation": {
                        "file": name,
                        "format": inspected["format"],
                        "kindle_locator_map": False,
                    },
                }
            )
    from kfxlib import KFXDRMError, set_logger
    from kindle_personal.mapped_kfx import mapped_epub

    logger = logging.Logger("android-kfx-private", logging.CRITICAL + 1)
    logger.addHandler(logging.NullHandler())
    logger.propagate = False
    set_logger(logger)
    package = root / "book.kfx-zip"
    try:
        with zipfile.ZipFile(package, "w", compression=zipfile.ZIP_STORED) as archive:
            for item in receipt["resources"]:
                name = item["file"]
                if Path(name).name != name:
                    raise ValueError()
                archive.write(root / name, arcname=name)
        (root / "ready.epub").write_bytes(mapped_epub(package))
        if not inspect_file(root / "ready.epub")["importable"]:
            return json.dumps(
                {"ok": False, "error": {"code": "conversion_unsupported"}}
            )
        return json.dumps(
            {
                "ok": True,
                "preparation": {
                    "file": "ready.epub",
                    "format": "epub",
                    "kindle_locator_map": True,
                },
            }
        )
    except KFXDRMError:
        return json.dumps({"ok": False, "error": {"code": "kfx_protected"}})
    except Exception:
        return json.dumps({"ok": False, "error": {"code": "conversion_unsupported"}})
    finally:
        package.unlink(missing_ok=True)
