"""Validate native files and prepare downloads offline.

The standalone companion converts unencrypted KFX in a separate process;
Calibre remains optional for other formats. No converter or private key enters
the Flutter app. A download is never, by itself, reported as readable.
"""

import os
import posixpath
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from urllib.parse import unquote, urlsplit

from defusedxml import ElementTree as ET
from defusedxml.common import DefusedXmlException

from .common import KindleError, file_hash, read_json, write_json

FONT_ALGORITHMS = {
    "http://www.idpf.org/2008/embedding",
    "http://ns.adobe.com/pdf/enc#RC",
}


def _archive_xml(archive, name):
    info = archive.getinfo(name)
    if info.file_size > 16 * 1024 * 1024:
        raise ValueError("Metadata too large")
    return ET.fromstring(archive.read(info))


def _local(tag):
    return tag.rsplit("}", 1)[-1]


def inspect_file(path: Path):
    """Return format/importability, not an assertion of visual correctness."""
    with path.open("rb") as stream:
        prefix = stream.read(4096)
    if prefix.startswith(b"%PDF-"):
        from pypdf import PdfReader
        from pypdf.errors import PyPdfError

        try:
            reader = PdfReader(path, strict=True)
            if reader.is_encrypted:
                return {"format": "pdf", "importable": False, "reason": "pdf_encrypted"}
            if len(reader.pages) < 1:
                raise ValueError()
            return {"format": "pdf", "importable": True, "reason": "native_pdf"}
        except (PyPdfError, ValueError, OSError):
            return {"format": "pdf", "importable": False, "reason": "invalid_pdf"}
    if prefix[60:68] == b"BOOKMOBI":
        return {"format": "mobi", "importable": False, "reason": "conversion_required"}
    if prefix.startswith((b"CONT", b"\xeaDRMION\xee", b"\xe0\x01\x00\xea")):
        return {
            "format": "kfx",
            "importable": False,
            "reason": "compatibility_required",
        }
    if zipfile.is_zipfile(path):
        try:
            with zipfile.ZipFile(path) as archive:
                names = archive.namelist()
                if len(names) > 65536 or len(names) != len(set(names)):
                    raise ValueError()
                if any(i.flag_bits & 1 for i in archive.infolist()):
                    return {
                        "format": "zip",
                        "importable": False,
                        "reason": "encrypted_zip",
                    }
                if (
                    "mimetype" not in names
                    or archive.getinfo("mimetype").file_size > 256
                    or archive.read("mimetype") != b"application/epub+zip"
                ):
                    return {"format": "zip", "importable": False, "reason": "not_epub"}
                if sum(i.file_size for i in archive.infolist()) > 1024 * 1024 * 1024:
                    raise ValueError()
                container = _archive_xml(archive, "META-INF/container.xml")
                package = next(
                    e.attrib["full-path"]
                    for e in container.iter()
                    if _local(e.tag) == "rootfile"
                )
                if (
                    package.startswith("/")
                    or ".." in package.split("/")
                    or "\\" in package
                ):
                    raise ValueError()
                opf = _archive_xml(archive, package)
                manifest = {
                    e.attrib["id"]: e.attrib["href"]
                    for e in opf.iter()
                    if _local(e.tag) == "item"
                }
                spine = [
                    e.attrib["idref"] for e in opf.iter() if _local(e.tag) == "itemref"
                ]
                if not spine:
                    raise ValueError()
                for entry in spine:
                    href = urlsplit(manifest[entry])
                    target = posixpath.normpath(
                        posixpath.join(posixpath.dirname(package), unquote(href.path))
                    )
                    if (
                        href.scheme
                        or href.netloc
                        or target.startswith(("../", "/"))
                        or "\\" in target
                    ):
                        raise ValueError()
                    info = archive.getinfo(target)
                    if info.file_size == 0:
                        raise ValueError()
                if "META-INF/encryption.xml" in names:
                    encryption = _archive_xml(archive, "META-INF/encryption.xml")
                    algorithms = [
                        e.attrib.get("Algorithm", "")
                        for e in encryption.iter()
                        if _local(e.tag) == "EncryptionMethod"
                    ]
                    if not algorithms or any(
                        a not in FONT_ALGORITHMS for a in algorithms
                    ):
                        return {
                            "format": "epub",
                            "importable": False,
                            "reason": "epub_protection",
                        }
                if archive.testzip() is not None:
                    raise ValueError()
                return {"format": "epub", "importable": True, "reason": "native_epub"}
        except (
            KeyError,
            StopIteration,
            ValueError,
            OSError,
            zipfile.BadZipFile,
            ET.ParseError,
            DefusedXmlException,
        ):
            return {"format": "epub", "importable": False, "reason": "invalid_epub"}
    return {"format": "unknown", "importable": False, "reason": "format_unsupported"}


def find_converter(explicit=None):
    if explicit:
        path = Path(explicit).expanduser().resolve()
        if not path.is_file():
            raise KindleError(
                "converter_missing",
                "Percorso ebook-convert non valido.",
                stage="prepare",
            )
        return str(path)
    executable = shutil.which("ebook-convert")
    if executable:
        return executable
    if os.name == "nt":
        for variable in ("ProgramFiles", "ProgramFiles(x86)"):
            if os.environ.get(variable):
                path = Path(os.environ[variable]) / "Calibre2" / "ebook-convert.exe"
                if path.is_file():
                    return str(path)
    return None


def _run_converter(executable, source, output, *, builtin=False):
    # PyInstaller changes the Windows DLL search directory. A separately
    # installed Calibre must load its own DLLs, not the prototype's Python DLLs.
    reset_dlls = os.name == "nt" and hasattr(sys, "_MEIPASS")
    if reset_dlls:
        import ctypes

        ctypes.windll.kernel32.SetDllDirectoryW(None)
    try:
        arguments = [executable, str(source), str(output)]
        environment = None
        if builtin:
            # A frozen child starts an independent application, not another
            # process sharing the parent's PyInstaller temporary state.
            entry = (
                []
                if getattr(sys, "frozen", False)
                else [
                    str(
                        Path(__file__).resolve().parent.parent
                        / "kindle_personal_cli.py"
                    )
                ]
            )
            arguments = [
                sys.executable,
                *entry,
                "convert-kfx",
                str(source),
                str(output),
            ]
            environment = {**os.environ, "PYINSTALLER_RESET_ENVIRONMENT": "1"}
        return subprocess.run(
            arguments,
            shell=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=600,
            env=environment,
        )
    finally:
        if reset_dlls:
            ctypes.windll.kernel32.SetDllDirectoryW(sys._MEIPASS)


def verified_receipt(directory: Path):
    receipt = read_json(directory / "receipt.json")
    if (
        not receipt
        or receipt.get("download_state") != "complete"
        or not receipt.get("resources")
    ):
        raise KindleError(
            "download_incomplete", "Download completo non disponibile.", stage="prepare"
        )
    for part in receipt["resources"]:
        name = part["file"]
        if Path(name).name != name or "/" in name or "\\" in name:
            raise KindleError(
                "local_resource", "Percorso risorsa non valido.", stage="prepare"
            )
        path = directory / name
        if (
            not path.is_file()
            or path.stat().st_size != part["bytes"]
            or file_hash(path) != part["sha256"]
        ):
            raise KindleError(
                "local_integrity",
                "Risorsa scaricata assente o modificata. Riscarica il titolo.",
                stage="prepare",
            )
    return receipt


def prepare_download(directory: Path, *, converter=None, convert=False, inline=False):
    receipt = verified_receipt(directory)
    previous = read_json(directory / "preparation.json", {})
    name = previous.get("file", "")
    if (
        previous.get("state") == "importable"
        and name
        and Path(name).name == name
        and "/" not in name
        and "\\" not in name
    ):
        ready = directory / name
        if (
            ready.is_file()
            and file_hash(ready) == previous.get("sha256")
            and inspect_file(ready)["importable"]
        ):
            return previous
    bases = [p for p in receipt["resources"] if p["type"] == "KINDLE_MAIN_BASE"]
    result = {
        "schema": 1,
        "download_state": "complete",
        "state": "needs_conversion",
        "reason": "format_unsupported",
        "opened_in_kmreader": False,
    }
    # Only an independently readable base without attachable content can be
    # imported as-is. Otherwise conversion needs the entire resource package.
    if len(bases) == 1 and not any(
        p["type"] == "KINDLE_MAIN_ATTACHABLE" for p in receipt["resources"]
    ):
        source = directory / bases[0]["file"]
        inspected = inspect_file(source)
        result.update({"format": inspected["format"], "reason": inspected["reason"]})
        if inspected["importable"]:
            output = directory / ("ready." + inspected["format"])
            with tempfile.TemporaryDirectory(
                prefix=".prepare-", dir=directory
            ) as temporary:
                staged = Path(temporary) / output.name
                shutil.copyfile(source, staged)
                os.replace(staged, output)
            result.update(
                state="importable", file=output.name, sha256=file_hash(output)
            )
            write_json(directory / "preparation.json", result)
            return result
    else:
        result.update(format="resource_set", reason="resource_set_conversion")
    kfx = any(
        inspect_file(directory / part["file"])["format"] == "kfx" for part in bases
    )
    executable = None
    builtin = convert and kfx and converter is None
    if convert and not builtin:
        executable = find_converter(converter)
        if not executable:
            result.update(reason="calibre_missing")
    if builtin or executable:
        with tempfile.TemporaryDirectory(
            prefix=".prepare-", dir=directory
        ) as temporary:
            temporary = Path(temporary)
            if len(bases) == 1 and result.get("format") == "mobi":
                source = directory / bases[0]["file"]
            else:
                # Preserve the complete resource set, including split content.
                source = temporary / "book.kfx-zip"
                with zipfile.ZipFile(
                    source, "w", compression=zipfile.ZIP_STORED
                ) as archive:
                    for part in receipt["resources"]:
                        archive.write(directory / part["file"], arcname=part["file"])
            output = temporary / "ready.epub"
            try:
                if builtin and inline:
                    from .kfx_conversion import convert_kfx

                    process = subprocess.CompletedProcess(
                        [], convert_kfx(source, output)
                    )
                else:
                    process = (
                        _run_converter(executable, source, output, builtin=True)
                        if builtin
                        else _run_converter(executable, source, output)
                    )
            except subprocess.TimeoutExpired:
                process = None
                result.update(reason="conversion_timeout")
            except OSError:
                process = None
                result.update(reason="converter_start")
            if process is not None:
                if (
                    process.returncode == 0
                    and output.is_file()
                    and inspect_file(output)["importable"]
                ):
                    final = directory / "ready.epub"
                    os.replace(output, final)
                    result.update(
                        state="importable",
                        reason="converted_epub",
                        format="epub",
                        file=final.name,
                        sha256=file_hash(final),
                        kindle_locator_map=builtin,
                    )
                else:
                    result.update(reason="conversion_unsupported")
                    if builtin:
                        result.update(
                            reason={
                                4: "kfx_protected",
                                6: "kfx_converter_missing",
                            }.get(process.returncode, "kfx_conversion_unsupported")
                        )
    write_json(directory / "preparation.json", result)
    return result
