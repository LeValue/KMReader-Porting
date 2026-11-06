"""Read-only progressive KFX experiments; reports contain counters, not books."""

import json
import shutil
import tempfile
import time
import tracemalloc
import os
from pathlib import Path

from .common import KindleError
from .kfx_progressive import ProgressiveKfx, PositionMap, quiet_library, utf16_length
from .range_source import FileRangeSource, RangeSource


def process_memory():
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes

        class Counters(ctypes.Structure):
            _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD)] + [
                (name, ctypes.c_size_t)
                for name in (
                    "PeakWorkingSetSize",
                    "WorkingSetSize",
                    "QuotaPeakPagedPoolUsage",
                    "QuotaPagedPoolUsage",
                    "QuotaPeakNonPagedPoolUsage",
                    "QuotaNonPagedPoolUsage",
                    "PagefileUsage",
                    "PeakPagefileUsage",
                )
            ]

        counters = Counters()
        counters.cb = ctypes.sizeof(counters)
        kernel = ctypes.WinDLL("kernel32")
        kernel.GetCurrentProcess.restype = wintypes.HANDLE
        psapi = ctypes.WinDLL("psapi")
        psapi.GetProcessMemoryInfo.argtypes = [
            wintypes.HANDLE,
            ctypes.POINTER(Counters),
            wintypes.DWORD,
        ]
        if psapi.GetProcessMemoryInfo(
            kernel.GetCurrentProcess(), ctypes.byref(counters), counters.cb
        ):
            return {
                "rss_bytes": counters.WorkingSetSize,
                "peak_rss_bytes": counters.PeakWorkingSetSize,
            }
    elif Path("/proc/self/status").is_file():
        values = {}
        for line in Path("/proc/self/status").read_text().splitlines():
            if line.startswith(("VmRSS:", "VmHWM:")):
                values[line.split(":")[0]] = int(line.split()[1]) * 1024
        return {"rss_bytes": values.get("VmRSS"), "peak_rss_bytes": values.get("VmHWM")}
    return {"rss_bytes": None, "peak_rss_bytes": None}


def progressive_probe(source, *, section=None, profile_allocations=False):
    if profile_allocations:
        tracemalloc.start()
    memory_before = process_memory()
    started = time.perf_counter()
    try:
        decoder = ProgressiveKfx(source)
        candidates = (
            [section] if section is not None else range(min(12, len(decoder.sections)))
        )
        chunks = []
        selected = None
        for candidate in candidates:
            chunks = decoder.section_chunks(candidate)
            if any(chunk.text and len(chunk.text.strip()) > 20 for chunk in chunks):
                selected = candidate
                break
        if selected is None:
            raise KindleError(
                "probe_no_text",
                "Nessuna sezione di testo supportata individuata.",
                stage="probe",
            )
        text_ready_ms = (time.perf_counter() - started) * 1000
        text_ready = source.metrics()
        mapped = decoder.original_positions(chunks)
        if not mapped:
            raise KindleError(
                "probe_position_unmapped",
                "Mappa posizioni non disponibile.",
                stage="probe",
            )
        positions = PositionMap(mapped)
        roundtrips = 0
        for index, chunk in enumerate(positions.chunks):
            for offset in sorted({0, len(chunk["text"]) // 2, len(chunk["text"]) - 1}):
                if offset < 0:
                    continue
                utf16 = utf16_length(chunk["text"][:offset])
                position = positions.from_text(index, utf16)
                if positions.to_text(position) != (index, utf16):
                    raise KindleError(
                        "probe_position_roundtrip",
                        "Mappa posizioni non reversibile.",
                        stage="probe",
                    )
                roundtrips += 1
        before = source.bytes_received
        decoder.section_chunks(selected)
        decoder.original_positions(chunks)
        repeated_bytes = source.bytes_received - before
        _, peak = tracemalloc.get_traced_memory() if profile_allocations else (0, None)
        result = {
            "schema": 1,
            "kind": "kfx_progressive_probe",
            "amazon_writes": False,
            "layout_verified": False,
            "section_count": len(decoder.sections),
            "section_index": selected,
            "text_chunks": len(mapped),
            "text_characters": sum(len(chunk["text"]) for chunk in mapped),
            "bootstrap_ms": round(decoder.bootstrap_ms, 2),
            "first_section_text_ms": round(text_ready_ms, 2),
            "first_section_transfer": text_ready,
            "with_position_map_transfer": source.metrics(),
            "revisit_additional_bytes": repeated_bytes,
            "position_roundtrips": roundtrips,
            "python_peak_allocated_bytes": peak,
            "timings_include_allocation_profiler": profile_allocations,
            "process_memory_before": memory_before,
            "process_memory_after": process_memory(),
        }
        return result, mapped
    finally:
        if profile_allocations:
            tracemalloc.stop()


def file_probe(path):
    from kfxlib import YJ_Book

    quiet_library()
    source = FileRangeSource(path)
    try:
        report, mapped = progressive_probe(source, profile_allocations=True)
    finally:
        source.close()
    # Reference decoding is separate from the measured partial-decoding phase.
    with tempfile.TemporaryDirectory() as temporary:
        full_path = Path(temporary) / "reference.kfx"
        shutil.copyfile(path, full_path)
        started = time.perf_counter()
        tracemalloc.start()
        try:
            full = YJ_Book(str(full_path))
            full.decode_book()
            reference = full.collect_content_position_info()
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        report["full_decode_ms"] = round((time.perf_counter() - started) * 1000, 2)
        report["full_decode_python_peak_allocated_bytes"] = peak
        by_anchor = {
            (str(chunk.eid), chunk.eid_offset): chunk
            for chunk in reference
            if chunk.text
        }
        for chunk in mapped:
            original = by_anchor.get((chunk["eid"], chunk["offset"]))
            if (
                original is None
                or original.pid != chunk["position"]
                or original.text != chunk["text"]
                or original.length != chunk["length"]
            ):
                raise KindleError(
                    "probe_reference_mismatch",
                    "Decodifica progressiva diversa dal riferimento completo.",
                    stage="probe",
                )
        report["matches_full_decode"] = True
    return report


def online_probe(client, item):
    from .download import _resource_urls, _stream_one

    manifest, headers = client.manifest(item)
    bases = [
        resource
        for resource in manifest["resources"]
        if resource.get("type") == "KINDLE_MAIN_BASE"
    ]
    if len(bases) != 1 or any(
        resource.get("type") == "KINDLE_MAIN_ATTACHABLE"
        for resource in manifest["resources"]
    ):
        raise KindleError(
            "probe_split_container",
            "Il probe incrementale iniziale richiede una risorsa principale senza allegati separati.",
            stage="probe",
        )
    last_error = None
    for url in _resource_urls(bases[0]):
        source = RangeSource(
            lambda range_headers: client.request(
                url, stage="probe", headers={**headers, **range_headers}
            )
        )
        try:
            report, _ = progressive_probe(source)
            report["transport"] = "amazon"
            report["matches_full_decode"] = None
            # Compare fewer/larger requests and the existing faithful EPUB
            # preparation path. No allocation tracing distorts user timings.
            larger = RangeSource(
                lambda range_headers: client.request(
                    url, stage="probe", headers={**headers, **range_headers}
                )
            )
            larger.block_size = 256 * 1024
            try:
                comparison, _ = progressive_probe(
                    larger, section=report["section_index"]
                )
                report["larger_blocks"] = comparison
            finally:
                larger.close()
            with tempfile.TemporaryDirectory() as temporary:
                from kfxlib import YJ_Book

                path = Path(temporary) / "book.kfx"
                started = time.perf_counter()
                transfer = _stream_one(
                    client,
                    url,
                    path,
                    headers,
                    max_bytes=256 * 1024 * 1024,
                    resource_type="KINDLE_MAIN_BASE",
                )
                downloaded = time.perf_counter()
                epub = YJ_Book(str(path)).convert_to_epub()
                report["full_download_and_epub"] = {
                    "download_ms": round((downloaded - started) * 1000, 2),
                    "conversion_ms": round(
                        (time.perf_counter() - downloaded) * 1000, 2
                    ),
                    "total_ms": round((time.perf_counter() - started) * 1000, 2),
                    "transferred_bytes": transfer["bytes"],
                    "epub_bytes": len(epub),
                    "decoder_already_loaded": True,
                }
                # Validate the app's exact-edition resume guard without ever
                # exporting IDs, note passages, credentials or book content.
                from .mapped_kfx import mapped_epub
                import io
                import zipfile

                mapped_started = time.perf_counter()
                prepared = mapped_epub(path)
                with zipfile.ZipFile(io.BytesIO(prepared)) as publication:
                    mapping = json.loads(
                        publication.read("META-INF/kmreader-kindle.json")
                    )
                verified = {
                    "entries": len(mapping["entries"]),
                    "conversion_ms": round(
                        (time.perf_counter() - mapped_started) * 1000, 2
                    ),
                    "sidecar_edition_matches": None,
                    "container_id_count": len(mapping["container_acrs"]),
                }
                try:
                    payload = json.loads(
                        client.bounded_get(
                            "https://cde-ta-g7g.amazon.com/FionaCDEServiceEngine/sidecar",
                            stage="probe",
                            params={"type": item["type"], "key": item["id"]},
                        )
                    )
                    payload = payload.get("payload", payload)
                    verified["sidecar_edition_matches"] = (
                        bool(payload.get("acr"))
                        and payload.get("acr") in mapping["container_acrs"]
                    )
                    verified["sidecar_acr_available"] = bool(payload.get("acr"))
                    verified["sidecar_guid_matches_container"] = (
                        payload.get("guid") in mapping["container_acrs"]
                    )
                    # Fiona can return the sidecar for a different delivered
                    # format unless its container GUID is requested explicitly.
                    targeted = []
                    for parameter in ("guid", "acr"):
                        if not mapping["container_acrs"]:
                            break
                        try:
                            variant = json.loads(
                                client.bounded_get(
                                    "https://cde-ta-g7g.amazon.com/FionaCDEServiceEngine/sidecar",
                                    stage="probe",
                                    params={
                                        "type": item["type"],
                                        "key": item["id"],
                                        parameter: mapping["container_acrs"][0],
                                    },
                                )
                            )
                            variant = variant.get("payload", variant)
                            targeted.append(
                                {
                                    "parameter": parameter,
                                    "edition_matches": variant.get("guid")
                                    in mapping["container_acrs"]
                                    or variant.get("acr") in mapping["container_acrs"],
                                }
                            )
                        except (KindleError, ValueError, TypeError, AttributeError):
                            targeted.append(
                                {"parameter": parameter, "available": False}
                            )
                    verified["targeted_sidecars"] = targeted
                    records = payload.get("records", [])
                    recent = next(
                        (
                            r
                            for r in records
                            if isinstance(r, dict)
                            and r.get("type") == "kindle.most_recent_read"
                        ),
                        {},
                    )
                    location = recent.get("location")
                    try:
                        position = int(location)
                        verified["position_in_verified_map"] = any(
                            e["position"] <= position < e["position"] + e["length"]
                            for e in mapping["entries"]
                        )
                        verified["position_numeric"] = True
                    except (TypeError, ValueError):
                        verified["position_numeric"] = False
                except (KindleError, ValueError, TypeError, AttributeError):
                    pass
                report["normalized_position_map"] = verified
            return report
        except KindleError as error:
            last_error = error
        finally:
            source.close()
    raise last_error


def sidecar_probe(client, item):
    """GET only. Report presence/counts, never return annotation text or IDs."""
    import json

    raw = client.bounded_get(
        "https://cde-ta-g7g.amazon.com/FionaCDEServiceEngine/sidecar",
        stage="probe",
        params={"type": item["type"], "key": item["id"]},
    )
    if not raw.strip():
        return {
            "available": False,
            "position_available": False,
            "guid_available": False,
            "annotations": 0,
        }
    try:
        payload = json.loads(raw)
        payload = payload.get("payload", payload)
        records = payload.get("records", [])
        if not isinstance(payload, dict) or not isinstance(records, list):
            raise ValueError()
        position = next(
            (
                record
                for record in records
                if isinstance(record, dict)
                and record.get("type") in {"kindle.most_recent_read", "kindle.lpr"}
            ),
            None,
        )
        return {
            "available": True,
            "position_available": position is not None,
            "guid_available": bool(payload.get("guid")),
            "annotations": sum(
                1
                for record in records
                if isinstance(record, dict)
                and str(record.get("type", "")).startswith("kindle.")
                and record.get("type") not in {"kindle.most_recent_read", "kindle.lpr"}
            ),
        }
    except (ValueError, TypeError, AttributeError):
        raise KindleError(
            "probe_sidecar_shape", "Risposta posizioni non riconosciuta.", stage="probe"
        ) from None
