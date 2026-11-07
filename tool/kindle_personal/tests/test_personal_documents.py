"""Regressions for the 0.1.0 personal-document and dictionary report."""

import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import httpx

from tool.kindle_personal.catalog import (
    CLASSIFICATION_VERSION,
    parse_catalog,
    synchronize,
    visible_items,
)
from tool.kindle_personal.cli import Application
from tool.kindle_personal.client import KindleClient
from tool.kindle_personal.common import KindleError, read_json, write_json
from tool.kindle_personal.download import download_book
from tool.kindle_personal.selfcheck import (
    MemoryVault,
    synthetic_epub,
    synthetic_session,
)


def catalog_item(
    identifier, *, kind="EBOK", title="Dictionary in a novel", tags="", origins=""
):
    return f"<meta_data><ASIN>{identifier}</ASIN><cde_contenttype>{kind}</cde_contenttype><title>{title}</title>{tags}{origins}</meta_data>"


class ShelfTest(unittest.TestCase):
    def snapshot(self):
        free = "<content_tags><tag>DICT</tag><tag>FREE_DICT</tag></content_tags>"
        dictionary = "<content_tags><tag>DICT</tag></content_tags>"
        purchase = "<origins><origin><type>Purchase</type><id>PRIVATE_ORDER</id></origin></origins>"
        raw = (
            "<response><sync_time>cursor</sync_time><add_update_list>"
            + "".join(
                [
                    catalog_item("free", tags=free),
                    catalog_item("bundled", tags=dictionary),
                    catalog_item("bought", tags=dictionary, origins=purchase),
                    catalog_item("novel"),
                    catalog_item("personal", kind="PDOC", tags=free),
                ]
            )
            + "</add_update_list></response>"
        )
        return parse_catalog(raw.encode(), limit=10000)

    def test_amazon_tags_hide_bundled_dictionaries_without_guessing_from_titles(self):
        snapshot = self.snapshot()
        self.assertEqual(
            {item["id"] for item in visible_items(snapshot)},
            {"bought", "novel", "personal"},
        )
        self.assertEqual(len(visible_items(snapshot, include_dictionaries=True)), 5)
        self.assertNotIn("PRIVATE_ORDER", json.dumps(snapshot))

    def test_old_cached_catalog_is_refreshed_without_registering_a_new_device(self):
        with tempfile.TemporaryDirectory() as temporary:
            client = KindleClient(MemoryVault(synthetic_session()))
            try:
                app = Application(Path(temporary), client=client)
                write_json(
                    app.account_directory / "catalog.json",
                    {"schema": 1, "items": [], "sync_time": "old"},
                )
                with patch.object(
                    app, "library", return_value=self.snapshot()
                ) as refresh:
                    result = app.cached_library()
                refresh.assert_called_once_with(full=True)
                self.assertEqual(
                    result["classification_version"], CLASSIFICATION_VERSION
                )
            finally:
                client.close()

    def test_numeric_selection_matches_the_filtered_list_and_all_view(self):
        with tempfile.TemporaryDirectory() as temporary:
            client = KindleClient(MemoryVault(synthetic_session()))
            try:
                app = Application(Path(temporary), client=client)
                write_json(app.account_directory / "catalog.json", self.snapshot())
                result = {"state": "needs_conversion", "reason": "test"}
                with (
                    patch(
                        "tool.kindle_personal.cli.download_book",
                        return_value=(Path(temporary), result),
                    ) as acquire,
                    redirect_stdout(io.StringIO()),
                ):
                    app.download("1")
                    self.assertEqual(acquire.call_args.args[1]["id"], "bought")
                    app.include_dictionaries = True
                    app.download("1")
                    self.assertEqual(acquire.call_args.args[1]["id"], "free")
                    app.include_dictionaries = False
                    app.download("EBOK:free")
                    self.assertEqual(acquire.call_args.args[1]["id"], "free")
            finally:
                client.close()

    def test_removal_list_and_full_response_do_not_leave_stale_items(self):
        prior = self.snapshot()
        raw = b'<response syncType="full"><sync_time>new</sync_time><add_update_list/><removal_list><ASIN>personal</ASIN></removal_list></response>'
        client = KindleClient(
            MemoryVault(synthetic_session()),
            transport=httpx.MockTransport(
                lambda request: httpx.Response(200, content=raw)
            ),
        )
        try:
            self.assertEqual(
                parse_catalog(raw, limit=10000)["removed"],
                [{"id": "personal", "type": ""}],
            )
            self.assertEqual(synchronize(client, prior)["items"], [])
        finally:
            client.close()


class PersonalDocumentTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.item = {
            "key": "PDOC:private-id",
            "id": "private-id",
            "type": "PDOC",
            "title": "PRIVATE_TITLE",
            "authors": [],
        }
        self.epub = synthetic_epub()
        self.extra = {
            "id": "PRIVATE_NOTE_ID",
            "type": "KINDLE_USER_ANOT",
            "requirement": "DEFERRED",
            "endpoint": {
                "url": "https://kindle-digital-delivery.amazon.com/notes?signature=PRIVATE"
            },
        }
        self.payload = b'<response><book><bookmark begin="1"/></book></response>'
        self.mime, self.status = "application/xml", 200
        self.seen = []
        self.direct_error = False

        def handle(request):
            self.seen.append(request)
            if "/delivery/manifest/" in request.url.path:
                return httpx.Response(
                    200,
                    json={
                        "content": {"id": self.item["id"]},
                        "resources": [
                            {
                                "id": "base",
                                "type": "KINDLE_MAIN_BASE",
                                "requirement": "REQUIRED",
                                "optimalEndpoint": {
                                    "directUrl": "https://content.cloudfront.net/base"
                                },
                                "endpoint": {
                                    "url": "https://kindle-digital-delivery.amazon.com/base"
                                },
                            },
                            self.extra,
                        ],
                    },
                )
            if request.url.path == "/base":
                if self.direct_error and request.url.host == "content.cloudfront.net":
                    return httpx.Response(
                        200,
                        stream=httpx.ByteStream(
                            b"<Error><Code>ExpiredToken</Code></Error>"
                        ),
                        headers={"content-type": "application/xml"},
                    )
                return httpx.Response(200, stream=httpx.ByteStream(self.epub))
            return httpx.Response(
                self.status,
                stream=httpx.ByteStream(self.payload),
                headers={"content-type": self.mime},
            )

        self.client = KindleClient(
            MemoryVault(synthetic_session()), transport=httpx.MockTransport(handle)
        )

    def tearDown(self):
        self.client.close()
        self.temporary.cleanup()

    def test_pdoc_followed_by_valid_xml_notes_is_downloaded_and_importable(self):
        directory, result = download_book(self.client, self.item, self.root)
        self.assertEqual(result["state"], "importable")
        receipt = read_json(directory / "receipt.json")
        self.assertEqual(len(receipt["resources"]), 2)
        self.assertEqual(receipt["resources"][1]["payload_kind"], "xml")
        self.assertEqual(
            (directory / receipt["resources"][1]["file"]).read_bytes(), self.payload
        )
        self.assertFalse(receipt["optional_resources_skipped"])

    def test_required_json_metadata_is_a_valid_resource(self):
        self.extra.update(type="KINDLE_MAIN_METADATA", requirement="REQUIRED")
        self.payload, self.mime = (
            b'{"metadata":{"title":"PRIVATE_TITLE"},"version":1}',
            "application/json; charset=utf-8",
        )
        directory, result = download_book(self.client, self.item, self.root)
        self.assertEqual(result["state"], "importable")
        self.assertEqual(
            read_json(directory / "receipt.json")["resources"][1]["payload_kind"],
            "json",
        )

    def test_unavailable_deferred_annotations_do_not_abort_the_document(self):
        for status, body in (
            (404, b"missing"),
            (200, b'{"error":{"message":"PRIVATE_BODY"}}'),
            (200, b""),
        ):
            with self.subTest(status=status, body=body):
                self.extra["id"] += "-revision"
                self.status, self.payload, self.mime = status, body, "application/json"
                directory, result = download_book(self.client, self.item, self.root)
                self.assertEqual(result["state"], "importable")
                receipt = read_json(directory / "receipt.json")
                self.assertEqual(len(receipt["resources"]), 1)
                self.assertEqual(len(receipt["optional_resources_skipped"]), 1)
                self.assertNotIn("PRIVATE_BODY", json.dumps(receipt))

    def test_required_annotation_failure_is_not_marked_complete(self):
        self.extra["requirement"] = "REQUIRED"
        self.payload, self.mime = b'{"error":"PRIVATE_BODY"}', "application/json"
        with self.assertRaises(KindleError) as failed:
            download_book(self.client, self.item, self.root)
        diagnostic = failed.exception.diagnostic()
        self.assertEqual(diagnostic["http_status"], 200)
        self.assertEqual(
            diagnostic["resource"],
            {
                "resource_type": "KINDLE_USER_ANOT",
                "resource_index": 2,
                "resource_count": 2,
                "book_type": "PDOC",
                "payload_kind": "json",
            },
        )
        for private in (
            "PRIVATE_BODY",
            "PRIVATE_NOTE_ID",
            "PRIVATE_TITLE",
            "private-id",
            "signature",
        ):
            self.assertNotIn(private, json.dumps(diagnostic))
        self.assertFalse(list(self.root.glob("*/*/receipt.json")))

    def test_core_metadata_service_error_and_malformed_xml_are_not_accepted(self):
        self.extra.update(type="KINDLE_MAIN_METADATA", requirement="REQUIRED")
        for payload, mime in (
            (b'{"error":"PRIVATE"}', "application/json"),
            (b"<Error><Message>PRIVATE</Message></Error>", "application/xml"),
            (b"<metadata>broken", "text/xml"),
            (b"<html>login</html>", "application/octet-stream"),
        ):
            with self.subTest(mime=mime), self.assertRaises(KindleError):
                self.payload, self.mime = payload, mime
                download_book(self.client, self.item, self.root)
        self.assertFalse(list(self.root.glob("*/*/receipt.json")))

    def test_http_200_cdn_error_falls_back_to_the_authenticated_manifest_endpoint(self):
        self.direct_error = True
        _, result = download_book(self.client, self.item, self.root)
        self.assertEqual(result["state"], "importable")
        requests = [r for r in self.seen if r.url.path == "/base"]
        self.assertEqual(len(requests), 2)
        self.assertNotIn("x-adp-token", requests[0].headers)
        self.assertIn("x-adp-token", requests[1].headers)


if __name__ == "__main__":
    unittest.main()
