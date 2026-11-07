"""GET-only schema and cover timings. No identifiers, passages or URLs leave here."""

import json
import re
import time
from defusedxml import ElementTree as ET

from .common import KindleError


def services_probe(client, item):
    from .cover import extract_cover, MAX_TRANSFER
    from .range_source import RangeSource
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
                "position_numeric": str(r.get("startPosition", "")).isdigit(),
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
    report["xml_filters"] = {}
    for kind in ("bookmark", "highlight", "note", "all"):
        try:
            raw = client.bounded_get(
                base + "getAnnotations",
                stage="probe",
                params={**params, "guid": payload.get("guid", ""), "filter": kind},
            )
            root = ET.fromstring(raw)
            report["xml_filters"][kind] = sorted(
                set(
                    e.tag.rsplit("}", 1)[-1] + ":" + ",".join(sorted(e.attrib))
                    for e in root.iter()
                )
            )
        except KindleError as error:
            report["xml_filters"][kind] = {"code": error.code, "status": error.status}
        except Exception:
            report["xml_filters"][kind] = {"unrecognized": True}
    started = time.perf_counter()
    try:
        manifest, headers = client.manifest(item)
        transferred = 0

        class Bounded:
            def __init__(self, response):
                self.response = response
                self.status_code = response.status_code
                self.headers = response.headers

            def iter_raw(self):
                nonlocal transferred
                for chunk in self.response.iter_raw():
                    transferred += len(chunk)
                    if transferred > MAX_TRANSFER:
                        raise ValueError("Transfer limit")
                    yield chunk

            def close(self):
                self.response.close()

        sources = []

        def request(urls, ranged):
            for url in urls:
                response = client.request(
                    url, stage="probe", headers={**headers, **ranged}
                )
                if response.status_code in (200, 206):
                    return Bounded(response)
                response.close()
            raise ValueError("Cover unavailable")

        try:
            for part in manifest["resources"]:
                if part.get("type") in {
                    "KINDLE_MAIN_BASE",
                    "KINDLE_MAIN_METADATA",
                    "KINDLE_MAIN_ATTACHABLE",
                }:
                    urls = _resource_urls(part)
                    source = RangeSource(
                        lambda ranged, urls=urls: request(urls, ranged),
                        full_limit=MAX_TRANSFER,
                    )
                    source.block_size = 256 * 1024
                    sources.append(source)
            cover = extract_cover(sources)
            cover["transferred"] = transferred
            cover["resources_bytes"] = sum(s.size or 0 for s in sources)
        finally:
            for source in sources:
                source.close()
        report["cover"] = {k: v for k, v in cover.items() if k != "image"}
        report["cover"]["available"] = bool(cover.get("image"))
    except KindleError as error:
        report["cover"] = {"available": False, "error_code": error.code}
    except Exception as error:
        report["cover"] = {"available": False, "error_type": type(error).__name__}
    report["cover_ms"] = round((time.perf_counter() - started) * 1000)
    return report
