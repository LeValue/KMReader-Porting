"""Progressive decoding, immutable transport and original-position contracts."""

import json
import tempfile
import unittest
from pathlib import Path

import httpx

from tool.kindle_personal.client import KindleClient
from tool.kindle_personal.common import KindleError
from tool.kindle_personal.kfx_progressive import (
    PositionMap,
    ProgressiveKfx,
    utf16_length,
)
from tool.kindle_personal.probe import file_probe, progressive_probe, sidecar_probe
from tool.kindle_personal.probe_fixtures import synthetic_progressive_kfx
from tool.kindle_personal.range_source import RangeSource
from tool.kindle_personal.selfcheck import MemoryVault, synthetic_session


class ProgressiveTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.body = synthetic_progressive_kfx()

    def source(
        self, *, full=False, mutate=False, invalid=False, missing_validator=False
    ):
        calls = []

        def request(headers):
            calls.append(headers)
            if full or mutate and len(calls) > 1:
                return httpx.Response(
                    200,
                    headers={"content-length": str(len(self.body))},
                    stream=httpx.ByteStream(self.body),
                )
            first, last = map(int, headers["Range"].split("=")[1].split("-"))
            last = min(last, len(self.body) - 1)
            response_headers = {
                "content-range": f"bytes {first}-{last}/{len(self.body)}",
                "etag": '"fixture-v1"',
            }
            if invalid:
                response_headers["content-range"] = (
                    f"bytes {first + 1}-{last}/{len(self.body)}"
                )
            if missing_validator:
                response_headers.pop("etag")
            return httpx.Response(
                206,
                headers=response_headers,
                stream=httpx.ByteStream(self.body[first : last + 1]),
            )

        source = RangeSource(request)
        self.addCleanup(source.close)
        return source, calls

    def test_first_text_and_original_positions_use_partial_content_and_cached_revisit(
        self,
    ):
        source, calls = self.source()
        report, chunks = progressive_probe(source)
        self.assertFalse(report["layout_verified"])
        self.assertLess(source.bytes_received, len(self.body))
        self.assertLess(source.cached_bytes, 4 * 1024 * 1024)
        self.assertEqual(report["revisit_additional_bytes"], 0)
        self.assertGreater(report["position_roundtrips"], 0)
        self.assertIn("😀", chunks[0]["text"])
        self.assertEqual(calls[1]["If-Range"], '"fixture-v1"')
        report_text = json.dumps(report)
        self.assertNotIn("Capitolo sintetico", report_text)
        self.assertNotIn('position":', report_text)

    def test_local_partial_decoding_matches_full_reference(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "book.kfx"
            path.write_bytes(self.body)
            self.assertTrue(file_probe(path)["matches_full_decode"])

    def test_random_section_keeps_global_original_positions(self):
        source, _ = self.source()
        decoder = ProgressiveKfx(source)
        first = decoder.original_positions(decoder.section_chunks(0))[0]
        last = decoder.original_positions(decoder.section_chunks(15))[0]
        self.assertGreater(last["position"], first["position"] + first["length"])
        self.assertIn("Capitolo sintetico 15", last["text"])
        self.assertLess(source.bytes_received, len(self.body))

    def test_no_range_support_falls_back_without_claiming_partial_transfer(self):
        source, _ = self.source(full=True)
        report, _ = progressive_probe(source)
        self.assertTrue(report["first_section_transfer"]["full_fallback"])
        self.assertEqual(
            report["first_section_transfer"]["transferred_bytes"], len(self.body)
        )
        self.assertEqual(report["revisit_additional_bytes"], 0)

    def test_changed_resource_is_never_mixed_with_cached_bytes(self):
        source, _ = self.source(mutate=True)
        source.read(0, 18)
        with self.assertRaises(KindleError) as error:
            source.read(128 * 1024, 18)
        self.assertEqual(error.exception.code, "range_changed")

    def test_wrong_range_and_missing_identity_are_rejected(self):
        for settings, reason in (
            ({"invalid": True}, "range_invalid"),
            ({"missing_validator": True}, "range_identity_missing"),
        ):
            with self.subTest(settings=settings):
                source, _ = self.source(**settings)
                with self.assertRaises(KindleError) as error:
                    source.read(0, 18)
                self.assertEqual(error.exception.code, reason)

    def test_cross_block_reads_and_lru_budget(self):
        source, _ = self.source()
        source.cache_budget = source.block_size
        self.assertEqual(
            source.read(source.block_size - 7, 80),
            self.body[source.block_size - 7 : source.block_size + 73],
        )
        self.assertLessEqual(source.cached_bytes, source.cache_budget)

    def test_utf16_dom_offsets_roundtrip_without_splitting_surrogate_pairs(self):
        text = "A😀 città e\u0301\nB"
        mapping = PositionMap([{"position": 500, "text": text, "length": len(text)}])
        for index in range(len(text)):
            offset = utf16_length(text[:index])
            self.assertEqual(mapping.from_text(0, offset), 500 + index)
            self.assertEqual(mapping.to_text(500 + index), (0, offset))
        for invalid in (-1, 2, utf16_length(text)):
            with self.assertRaises(ValueError):
                mapping.from_text(0, invalid)

    def test_cdn_receives_range_headers_but_never_signed_device_headers(self):
        def handle(request):
            self.assertEqual(request.headers["range"], "bytes=0-17")
            self.assertEqual(request.headers["if-range"], '"fixture-v1"')
            self.assertNotIn("x-adp-token", request.headers)
            self.assertNotIn("x-adp-signature", request.headers)
            self.assertNotIn("x-adp-correlationid", request.headers)
            return httpx.Response(206, content=self.body[:18])

        client = KindleClient(
            MemoryVault(synthetic_session()), transport=httpx.MockTransport(handle)
        )
        try:
            response = client.request(
                "https://synthetic.cloudfront.net/file",
                stage="probe",
                headers={
                    "Range": "bytes=0-17",
                    "If-Range": '"fixture-v1"',
                    "x-adp-correlationid": "PRIVATE",
                },
            )
            response.close()
        finally:
            client.close()

    def test_sync_probe_is_get_only_and_report_contains_no_annotation_or_guid(self):
        def handle(request):
            self.assertEqual(request.method, "GET")
            self.assertIn("x-adp-signature", request.headers)
            return httpx.Response(
                200,
                json={
                    "payload": {
                        "guid": "PRIVATE_GUID",
                        "records": [
                            {"type": "kindle.most_recent_read", "location": 100},
                            {"type": "kindle.highlight", "text": "PRIVATE_PASSAGE"},
                        ],
                    }
                },
            )

        client = KindleClient(
            MemoryVault(synthetic_session()), transport=httpx.MockTransport(handle)
        )
        try:
            report = sidecar_probe(client, {"id": "PRIVATE_ID", "type": "PDOC"})
            self.assertEqual(
                report,
                {
                    "available": True,
                    "position_available": True,
                    "guid_available": True,
                    "annotations": 1,
                },
            )
            self.assertNotIn("PRIVATE", json.dumps(report))
        finally:
            client.close()


if __name__ == "__main__":
    unittest.main()
