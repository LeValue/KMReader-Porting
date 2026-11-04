"""Atomic, complete acquisition of one fresh delivery manifest at a time."""

import base64
import hashlib
import json
import os
import shutil
import tempfile
import uuid
from pathlib import Path
from urllib.parse import urlencode

import httpx

from .client import check_url
from .common import KindleError, digest, write_json
from .prepare import prepare_download, verified_receipt
from .auth import SOFTWARE_VERSION

MAX_RESOURCE = 2 * 1024 * 1024 * 1024
MAX_BOOK = 4 * 1024 * 1024 * 1024
SUFFIXES = {
    "KINDLE_MAIN_BASE": ".azw",
    "KINDLE_MAIN_METADATA": ".azw.md",
    "KINDLE_MAIN_ATTACHABLE": ".azw.res",
    "DRM_VOUCHER": ".voucher",
    "KINDLE_USER_ANOT": ".mbpV2",
}


def _context(value):
    if isinstance(value, dict):
        return value
    if not value:
        return {}
    try:
        from amazon.ion import simpleion

        raw = base64.b64decode(value, validate=True)
        if len(raw) > 1024 * 1024:
            raise ValueError()
        return dict(simpleion.loads(raw))
    except Exception:
        # Ion parser exception types vary by implementation. Never expose its
        # message, which may contain the original opaque response context.
        raise KindleError(
            "manifest_context",
            "Contesto di consegna non riconosciuto.",
            stage="manifest",
        ) from None


def _resource_urls(resource):
    if (
        not isinstance(resource, dict)
        or not isinstance(resource.get("id"), str)
        or not isinstance(resource.get("type"), str)
    ):
        raise KindleError(
            "resource_shape", "Risorsa del manifest non riconosciuta.", stage="manifest"
        )
    urls = []
    for key, field in (("optimalEndpoint", "directUrl"), ("endpoint", "url")):
        endpoint = resource.get(key) or {}
        if not isinstance(endpoint, dict):
            raise KindleError(
                "resource_endpoint",
                "Endpoint del manifest non riconosciuto.",
                stage="manifest",
            )
        url = endpoint.get(field)
        method = endpoint.get("httpMethod", endpoint.get("method", "GET"))
        if method != "GET":
            raise KindleError(
                "resource_method",
                "Il manifest richiede un metodo di consegna non supportato.",
                stage="manifest",
            )
        if url and url not in urls:
            check_url(url)
            urls.append(url)
    if not urls:
        raise KindleError(
            "resource_endpoint",
            "Indirizzo risorsa assente nel manifest.",
            stage="manifest",
        )
    return urls


def _stream_part(client, urls, destination, headers, *, max_bytes):
    response = None
    for index, url in enumerate(urls):
        try:
            response = client.request(url, stage="download", headers=headers)
            break
        except KindleError as error:
            if error.status not in (401, 403) or index == len(urls) - 1:
                raise
    try:
        expected = response.headers.get("content-length")
        try:
            expected = int(expected) if expected is not None else None
        except ValueError:
            raise KindleError(
                "resource_length", "Dimensione risorsa non valida.", stage="download"
            ) from None
        if (
            response.status_code != 200
            or expected is not None
            and (expected < 1 or expected > max_bytes)
        ):
            raise KindleError(
                "resource_length",
                "La risorsa non è un download completo valido.",
                stage="download",
            )
        content_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
        if response.headers.get("content-encoding", "identity").lower() != "identity":
            raise KindleError(
                "resource_encoding",
                "Codifica del trasferimento non supportata.",
                stage="download",
            )
        if content_type in (
            "text/html",
            "application/json",
            "text/xml",
            "application/xml",
        ):
            raise KindleError(
                "resource_error_page",
                "Il server ha restituito una pagina di servizio al posto della risorsa.",
                stage="download",
            )
        size, sha = 0, hashlib.sha256()
        with destination.open("wb") as output:
            for chunk in response.iter_raw():
                size += len(chunk)
                if size > max_bytes:
                    raise KindleError(
                        "resource_size",
                        "Dimensione massima del download superata.",
                        stage="download",
                    )
                output.write(chunk)
                sha.update(chunk)
            output.flush()
            os.fsync(output.fileno())
        if size == 0 or expected is not None and size != expected:
            raise KindleError(
                "resource_truncated",
                "Download incompleto; il titolo precedente resta disponibile.",
                stage="download",
            )
        return {"bytes": size, "sha256": sha.hexdigest()}
    except httpx.HTTPError:
        raise KindleError(
            "resource_interrupted",
            "Download interrotto. Riprova il titolo.",
            stage="download",
        ) from None
    finally:
        response.close()


def download_book(
    client,
    item,
    root: Path,
    *,
    progress=lambda message: None,
    convert=False,
    converter=None,
):
    client.require_session()
    try:
        manifest, common_headers = client.manifest(item)
    except KindleError as error:
        if item["type"] != "PDOC" or error.status != 404:
            raise
        # Older personal documents may have no modern manifest. This is a
        # read-only legacy PDOC delivery endpoint, not a purchase/DRM downgrade.
        progress(
            "Manifest PDOC non disponibile: provo la consegna del documento storico."
        )
        url = (
            "https://cde-ta-g7g.amazon.com/FionaCDEServiceEngine/FSDownloadContent?"
            + urlencode(
                {
                    "type": "PDOC",
                    "key": item["id"],
                    "is_archived_items": 1,
                    "software_rev": SOFTWARE_VERSION,
                }
            )
        )
        manifest = {
            "content": {"id": item["id"]},
            "resources": [
                {
                    "id": item["id"],
                    "type": "KINDLE_MAIN_BASE",
                    "requirement": "REQUIRED",
                    "endpoint": {"url": url},
                }
            ],
        }
        common_headers = {}
    resources = manifest["resources"]
    if len(resources) > 4096 or not any(
        r.get("type") == "KINDLE_MAIN_BASE" for r in resources if isinstance(r, dict)
    ):
        raise KindleError(
            "manifest_resources",
            "Set di risorse del libro non supportato.",
            stage="manifest",
        )
    planned, identities = [], set()
    for index, resource in enumerate(resources):
        urls = _resource_urls(resource)
        identity = (resource["type"], resource["id"])
        if identity in identities:
            raise KindleError(
                "resource_duplicate",
                "Il manifest contiene risorse duplicate.",
                stage="manifest",
            )
        identities.add(identity)
        # Never use an ASIN, Content-Disposition or remote resource ID as a path.
        name = f"{index:04d}-{digest(resource['id'])[:16]}" + SUFFIXES.get(
            resource["type"], ".bin"
        )
        headers = dict(common_headers)
        if resource["type"] == "DRM_VOUCHER":
            context = _context(manifest.get("responseContext"))
            headers.update(
                {
                    "Accept": "application/x-com.amazon.drm.Voucher@1.0",
                    "X-ADP-LTO": "60",
                }
            )
            for field, header in (
                ("country", "X-ADP-Country"),
                ("transport", "X-ADP-Transport"),
                ("reason", "X-ADP-Reason"),
                ("swVersion", "X-ADP-SW"),
            ):
                if field in context:
                    headers[header] = str(context[field])
        planned.append((resource, urls, name, headers))
    content = manifest.get("content", {})
    revision_fields = {
        key: str(content[key])
        for key in ("revision", "version", "contentRevision", "contentVersion")
        if key in content
    }
    revision_fields["catalog_revision"] = item.get("revision", "")
    revision = digest(
        json.dumps(
            {"resources": sorted(identities), "content": revision_fields},
            ensure_ascii=False,
            sort_keys=True,
        )
    )[:16]
    book_directory = root / digest(item["key"])[:24]
    destination = book_directory / revision
    if (destination / "receipt.json").is_file():
        # Verifies every existing resource hash before using a completed cache.
        try:
            verified_receipt(destination)
        except KindleError:
            progress(
                "Copia locale incompleta o modificata: acquisisco di nuovo tutte le risorse."
            )
        else:
            return destination, prepare_download(
                destination, convert=convert, converter=converter
            )
    book_directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".download-", dir=book_directory
    ) as temporary:
        temporary = Path(temporary)
        receipt = {
            "schema": 1,
            "marketplace": "amazon.it",
            "book": item,
            "revision": revision,
            "download_state": "complete",
            "resources": [],
        }
        total = 0
        for index, (resource, urls, name, headers) in enumerate(planned):
            progress(f"Risorsa {index + 1}/{len(planned)}")
            info = _stream_part(
                client,
                urls,
                temporary / name,
                headers,
                max_bytes=min(MAX_RESOURCE, MAX_BOOK - total),
            )
            total += info["bytes"]
            receipt["resources"].append(
                {
                    "id": resource["id"],
                    "type": resource["type"],
                    "requirement": resource.get("requirement", "unknown"),
                    "file": name,
                    **info,
                }
            )
        # No signed URLs, opaque response context, cookies or device credentials
        # are written to this diagnostic record or passed to the converter.
        write_json(temporary / "receipt.json", receipt)
        backup = book_directory / (".replaced-" + uuid.uuid4().hex)
        if destination.exists():
            os.replace(destination, backup)
        try:
            os.replace(temporary, destination)
        except OSError:
            if backup.exists():
                os.replace(backup, destination)
            raise
        if backup.exists():
            shutil.rmtree(backup)
        # TemporaryDirectory tolerates the already moved staging directory.
    result = prepare_download(destination, convert=convert, converter=converter)
    return destination, result
