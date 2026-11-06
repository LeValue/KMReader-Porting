"""GET-only schema and cover timings. No identifiers, passages or URLs leave here."""

import json
import re
import time
from defusedxml import ElementTree as ET

from .common import KindleError


def services_probe(client, item):
    from .cover import allowed_cover_url, remote_cover
    from .download import _resource_urls

    report = {"amazon_writes": False}
    base = "https://cde-ta-g7g.amazon.com/FionaCDEServiceEngine/"
    params = {"type": item["type"], "key": item["id"]}
    try:
        payload = json.loads(
            client.bounded_get(base + "sidecar", stage="probe", params=params)
        )
        payload = payload.get("payload", payload)
        records = payload.get("records", [])
        # Only protocol field names and JSON types. Never record field values.
        report["records"] = [
            {
                "type": r["type"],
                "fields": {
                    k: type(v).__name__
                    for k, v in r.items()
                    if re.fullmatch(r"[a-zA-Z_][a-zA-Z_]{0,48}", k)
                },
                "location_shape": re.sub(
                    r"[0-9a-fA-F]", "#", str(r.get("location", ""))
                )[:100]
                if re.fullmatch(r"[0-9:.,-]{0,100}", str(r.get("location", "")))
                else "structured",
            }
            for r in records
            if isinstance(r, dict)
            and r.get("type")
            in {
                "kindle.bookmark",
                "kindle.highlight",
                "kindle.note",
                "kindle.most_recent_read",
                "kindle.lpr",
            }
        ]
    except Exception:
        report["records_error"] = True
    try:
        raw = client.bounded_get(base + "getAnnotations", stage="probe", params=params)
        root = ET.fromstring(raw)
        report["xml_schema"] = sorted(
            set(
                e.tag.rsplit("}", 1)[-1] + ":" + ",".join(sorted(e.attrib))
                for e in root.iter()
            )
        )
    except Exception:
        report["xml_error"] = True
    started = time.perf_counter()
    try:
        manifest, _ = client.manifest(item)
        urls = [
            url
            for part in manifest["resources"]
            if part.get("type")
            in {"KINDLE_MAIN_BASE", "KINDLE_MAIN_METADATA", "KINDLE_MAIN_ATTACHABLE"}
            for url in _resource_urls(part)
            if allowed_cover_url(url)
        ]
        cover = remote_cover(urls)
        report["cover"] = {k: v for k, v in cover.items() if k != "image"}
        report["cover"]["available"] = bool(cover.get("image"))
    except KindleError as error:
        report["cover"] = {"available": False, "error_code": error.code}
    except Exception as error:
        report["cover"] = {"available": False, "error_type": type(error).__name__}
    report["cover_ms"] = round((time.perf_counter() - started) * 1000)
    return report
