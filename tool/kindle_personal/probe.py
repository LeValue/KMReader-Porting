"""Read-only progressive KFX experiments; reports contain counters, not books."""

import shutil
import tempfile
import time
import tracemalloc
from pathlib import Path

from .common import KindleError
from .kfx_progressive import ProgressiveKfx, PositionMap, quiet_library, utf16_length
from .range_source import FileRangeSource, RangeSource


def progressive_probe(source, *, section=None):
    tracemalloc.start()
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
        _, peak = tracemalloc.get_traced_memory()
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
        }
        return result, mapped
    finally:
        tracemalloc.stop()


def file_probe(path):
    from kfxlib import YJ_Book

    quiet_library()
    source = FileRangeSource(path)
    try:
        report, mapped = progressive_probe(source)
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
    from .download import _resource_urls

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
