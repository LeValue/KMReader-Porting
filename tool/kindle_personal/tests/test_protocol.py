import base64
import hashlib
import io
import json
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlencode, urlsplit

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

from tool.kindle_personal.auth import LoginAttempt, registration_body
from tool.kindle_personal.catalog import parse_catalog, synchronize
from tool.kindle_personal.cli import Application, exclusive
from tool.kindle_personal.client import (
    CATALOG_URL,
    KindleClient,
    check_url,
    signing_headers,
)
from tool.kindle_personal.common import KindleError, file_hash, read_json, write_json
from tool.kindle_personal.download import download_book
from tool.kindle_personal.prepare import inspect_file, prepare_download
from tool.kindle_personal.selfcheck import (
    MemoryVault,
    self_check,
    synthetic_epub,
    synthetic_pdf,
    synthetic_session,
)
from tool.kindle_personal.storage import account_key


CATALOG = """<response xmlns="urn:test"><sync_time>cursor-1</sync_time><add_update_list>
<meta_data><ASIN>B0-CASE</ASIN><cde_contenttype>EBOK</cde_contenttype><title>Moby Dick: Or, The Whale</title>
<authors><author>Herman Melville</author><author>Autore è</author></authors></meta_data>
<meta_data><ASIN>opaque/Personal.Id-È</ASIN><cde_contenttype>PDOC</cde_contenttype><title>Il mio documento personale</title></meta_data>
</add_update_list></response>""".encode()


class AuthenticationTest(unittest.TestCase):
    def test_pkce_italian_device_profile_and_challenge(self):
        attempt = LoginAttempt("stable-serial")
        values = parse_qs(urlsplit(attempt.url()).query)
        self.assertEqual(urlsplit(attempt.url()).hostname, "www.amazon.it")
        self.assertEqual(values["openid.assoc_handle"], ["amzn_device_it"])
        self.assertEqual(values["pageId"], ["amzn_device_common_dark"])
        self.assertEqual(values["openid.oa2.response_type"], ["code"])
        self.assertEqual(values["openid.oa2.scope"], ["device_auth_access"])
        expected = (
            base64.urlsafe_b64encode(hashlib.sha256(attempt.verifier.encode()).digest())
            .decode()
            .rstrip("=")
        )
        self.assertEqual(values["openid.oa2.code_challenge"], [expected])
        body = registration_body(attempt, {"authorization_code": "test"})
        self.assertEqual(body["registration_data"]["device_serial"], attempt.serial)
        self.assertNotIn("password", json.dumps(body))

    def test_query_and_fragment_callbacks_and_legacy_flow(self):
        for flow, field in (("pkce", "authorization_code"), ("token", "access_token")):
            for separator in ("?", "#"):
                with self.subTest(flow=flow, separator=separator):
                    attempt = LoginAttempt("stable", flow)
                    result = attempt.callback(
                        "https://www.amazon.it/ap/maplanding"
                        + separator
                        + urlencode(
                            {
                                "openid.oa2." + field: "test-secret",
                                "openid.oa2.state": attempt.state,
                            }
                        )
                    )
                    self.assertEqual(result[field], "test-secret")
                    if flow == "pkce":
                        self.assertEqual(result["code_verifier"], attempt.verifier)

    def test_callback_rejects_lookalike_hosts_and_duplicate_or_wrong_state(self):
        attempt = LoginAttempt("serial")
        for base in (
            "http://www.amazon.it",
            "https://www.amazon.it.evil.example",
            "https://www.amazon.it@evil.example",
            "https://www.amazon.it:444",
            "https://amazon.it",
        ):
            self.assertIsNone(
                attempt.callback(
                    base + "/ap/maplanding?openid.oa2.authorization_code=secret"
                )
            )
        with self.assertRaises(KindleError):
            attempt.callback(
                "https://www.amazon.it/ap/maplanding?openid.oa2.state=wrong&openid.oa2.authorization_code=secret"
            )
        with self.assertRaises(KindleError):
            attempt.callback(
                "https://www.amazon.it/ap/maplanding?openid.oa2.authorization_code=a#openid.oa2.authorization_code=b"
            )

    def test_adp_signature_covers_encoded_path_query_method_body_and_token(self):
        session = synthetic_session()
        request = httpx.Request(
            "GET", "https://todo-ta-g7g.amazon.com/path/%C3%A8?x=a%20b&y=%2F"
        )
        timestamp = "2026-11-04T12:00:00Z"
        headers = signing_headers(request, session, timestamp=timestamp)
        signed, date = headers["x-adp-signature"].split(":", 1)
        key = serialization.load_pem_private_key(
            session["device_private_key"].encode(), password=None
        )
        message = f"GET\n/path/%C3%A8?x=a%20b&y=%2F\n{date}\n\n{session['adp_token']}".encode()
        key.public_key().verify(
            base64.b64decode(signed), message, padding.PKCS1v15(), hashes.SHA256()
        )

    def test_server_error_body_never_enters_exception_or_report(self):
        vault = MemoryVault()
        client = KindleClient(
            vault,
            transport=httpx.MockTransport(
                lambda r: httpx.Response(
                    403, json={"error": "access_token=VERY_PRIVATE"}
                )
            ),
        )
        try:
            with self.assertRaises(KindleError) as failure:
                client.register(
                    LoginAttempt("stable"), {"authorization_code": "PRIVATE_CODE"}
                )
            self.assertNotIn("PRIVATE", str(failure.exception))
            self.assertEqual(
                failure.exception.diagnostic(),
                {
                    "code": "amazon_http",
                    "stage": "register",
                    "http_status": 403,
                    "authentication": {
                        "flow": "pkce",
                        "entry": "device_it",
                        "reason": "unknown",
                        "response_format": "json",
                    },
                },
            )
            self.assertIsNone(vault.load())
        finally:
            client.close()

    def test_refresh_preserves_device_identity_and_persists_rotated_token(self):
        session = synthetic_session()
        session["expires"] = time.time() - 1
        seen = []

        def handle(request):
            seen.append(request)
            if request.url.path == "/auth/token":
                return httpx.Response(
                    200, json={"access_token": "new-access", "expires_in": 3600}
                )
            return httpx.Response(200, content=b"ok")

        vault = MemoryVault(session)
        client = KindleClient(vault, transport=httpx.MockTransport(handle))
        try:
            self.assertEqual(client.bounded_get(CATALOG_URL, stage="catalog"), b"ok")
            self.assertEqual(vault.session["access_token"], "new-access")
            self.assertEqual(vault.session["serial"], session["serial"])
            self.assertEqual(len(seen), 2)
            self.assertEqual(seen[0].url.host, "api.amazon.it")
        finally:
            client.close()


class CatalogTest(unittest.TestCase):
    def test_unicode_titles_authors_and_opaque_pdoc_ids_remain_intact(self):
        result = parse_catalog(CATALOG, limit=10000)
        self.assertTrue(result["complete"])
        self.assertEqual(result["items"][0]["title"], "Moby Dick: Or, The Whale")
        self.assertEqual(result["items"][0]["authors"], ["Herman Melville", "Autore è"])
        self.assertEqual(result["items"][1]["id"], "opaque/Personal.Id-È")

    def test_limit_and_server_pagination_are_not_called_complete(self):
        self.assertFalse(parse_catalog(CATALOG, limit=2)["complete"])
        for name in ("has_more", "has_more_items", "next_page_token", "truncated"):
            raw = CATALOG.replace(
                b"</response>", f"<{name}>true</{name}></response>".encode()
            )
            self.assertFalse(parse_catalog(raw, limit=10000)["complete"])

    def test_missing_shape_and_entity_expansion_fail_closed(self):
        for raw in (
            b"<html>login</html>",
            b"<response/>",
            b'<!DOCTYPE a [<!ENTITY secret SYSTEM "file:///etc/passwd">]><response><add_update_list>&secret;</add_update_list></response>',
        ):
            with self.assertRaises(KindleError):
                parse_catalog(raw, limit=10000)

    def test_incremental_query_applies_updates_and_deletions_without_losing_others(
        self,
    ):
        previous = parse_catalog(CATALOG, limit=10000)
        extra = {
            "key": "EBOK:keep",
            "id": "keep",
            "type": "EBOK",
            "title": "Keep",
            "authors": [],
        }
        previous["items"].append(extra)
        seen = []

        def handle(request):
            seen.append(request)
            return httpx.Response(
                200,
                content=b"<response><sync_time>cursor-2</sync_time><add_update_list/>"
                b"<delete_list><meta_data><ASIN>B0-CASE</ASIN><cde_contenttype>EBOK</cde_contenttype></meta_data></delete_list></response>",
            )

        client = KindleClient(
            MemoryVault(synthetic_session()), transport=httpx.MockTransport(handle)
        )
        try:
            result = synchronize(client, previous)
            self.assertEqual(seen[0].url.params["last_sync_time"], "cursor-1")
            self.assertEqual(seen[0].url.params["item_count"], "10000")
            self.assertEqual(
                {x["key"] for x in result["items"]},
                {extra["key"], "PDOC:opaque/Personal.Id-È"},
            )
        finally:
            client.close()


class DeliveryTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.item = {
            "key": "PDOC:../opaque/ID",
            "id": "../opaque/ID",
            "type": "PDOC",
            "title": "My doc",
            "authors": [],
        }
        self.manifest = {
            "content": {"id": self.item["id"]},
            "resources": [
                {
                    "id": "../../remote-resource",
                    "type": "KINDLE_MAIN_BASE",
                    "requirement": "REQUIRED",
                    "optimalEndpoint": {
                        "directUrl": "https://content.cloudfront.net/book?temporary=PRIVATE"
                    },
                    "endpoint": {
                        "url": "https://kindle-digital-delivery.amazon.com/resource/book"
                    },
                }
            ],
        }
        self.body = synthetic_epub()
        self.requests = []
        self.fail_download = None
        self.headers = {}
        self.seen_content = []

        def handle(request):
            self.requests.append(request)
            if "/delivery/manifest/" in request.url.path:
                return httpx.Response(200, json=self.manifest)
            self.seen_content.append(request)
            if self.fail_download:
                return self.fail_download(request)
            return httpx.Response(
                200, stream=httpx.ByteStream(self.body), headers=self.headers
            )

        self.client = KindleClient(
            MemoryVault(synthetic_session()), transport=httpx.MockTransport(handle)
        )

    def tearDown(self):
        self.client.close()
        self.temporary.cleanup()

    def test_download_sniffs_epub_and_hashes_complete_resources_without_saving_urls(
        self,
    ):
        directory, result = download_book(self.client, self.item, self.root)
        self.assertEqual(result["state"], "importable")
        self.assertFalse(result["opened_in_kmreader"])
        self.assertEqual((directory / "ready.epub").read_bytes(), self.body)
        receipt = read_json(directory / "receipt.json")
        self.assertEqual(
            receipt["resources"][0]["sha256"], hashlib.sha256(self.body).hexdigest()
        )
        self.assertNotIn("PRIVATE", (directory / "receipt.json").read_text())
        self.assertTrue(directory.is_relative_to(self.root))
        self.assertNotIn("x-adp-token", self.seen_content[0].headers)
        self.assertNotIn("x-adp-correlationid", self.seen_content[0].headers)

    def test_expired_direct_url_falls_back_once_to_signed_service(self):
        def failure(request):
            if request.url.host == "content.cloudfront.net":
                return httpx.Response(403)
            return httpx.Response(200, stream=httpx.ByteStream(self.body))

        self.fail_download = failure
        _, result = download_book(self.client, self.item, self.root)
        self.assertEqual(result["state"], "importable")
        self.assertEqual(len(self.seen_content), 2)
        self.assertIn("x-adp-token", self.seen_content[1].headers)

    def test_redirect_resigns_service_but_never_sends_device_keys_to_cdn(self):
        self.manifest["resources"][0].pop("optimalEndpoint")

        def failure(request):
            if request.url.host == "kindle-digital-delivery.amazon.com":
                return httpx.Response(
                    302,
                    headers={
                        "location": "https://content.cloudfront.net/final?signature=PRIVATE"
                    },
                )
            return httpx.Response(200, stream=httpx.ByteStream(self.body))

        self.fail_download = failure
        download_book(self.client, self.item, self.root)
        self.assertIn("x-adp-token", self.seen_content[0].headers)
        self.assertNotIn("x-adp-token", self.seen_content[1].headers)
        self.assertNotIn("x-adp-correlationid", self.seen_content[1].headers)

    def test_every_manifest_resource_is_saved_but_multiple_parts_need_conversion(self):
        for kind in (
            "KINDLE_MAIN_ATTACHABLE",
            "KINDLE_MAIN_METADATA",
            "UNKNOWN_FUTURE_RESOURCE",
        ):
            self.manifest["resources"].append(
                {
                    "id": kind,
                    "type": kind,
                    "requirement": "DEFERRED",
                    "endpoint": {"url": "https://content.cloudfront.net/" + kind},
                }
            )
        directory, result = download_book(self.client, self.item, self.root)
        self.assertEqual(len(read_json(directory / "receipt.json")["resources"]), 4)
        self.assertEqual(result["state"], "needs_conversion")
        self.assertFalse((directory / "ready.epub").exists())

    def test_cached_download_is_verified_and_reprepared_offline(self):
        directory, _ = download_book(self.client, self.item, self.root)
        self.client.close()
        (directory / "ready.epub").unlink()
        self.assertEqual(prepare_download(directory)["state"], "importable")
        receipt = read_json(directory / "receipt.json")
        (directory / receipt["resources"][0]["file"]).write_bytes(b"tampered")
        with self.assertRaises(KindleError) as failure:
            prepare_download(directory)
        self.assertEqual(failure.exception.code, "local_integrity")

    def test_interrupted_new_revision_keeps_previous_completed_copy(self):
        directory, _ = download_book(self.client, self.item, self.root)
        original_hash = file_hash(directory / "ready.epub")
        self.manifest["resources"][0]["id"] = "new-revision"
        self.headers = {"content-length": str(len(self.body) + 1)}
        with self.assertRaises(KindleError):
            download_book(self.client, self.item, self.root)
        self.assertEqual(file_hash(directory / "ready.epub"), original_hash)
        self.assertEqual(len(list(self.root.glob("*/*/receipt.json"))), 1)
        self.assertFalse(list(self.root.glob("*/.download-*")))

    def test_200_error_page_empty_transfer_and_partial_status_are_rejected(self):
        for status, body, headers in (
            (200, b"<html>login</html>", {"content-type": "text/html"}),
            (200, b"", {}),
            (206, b"partial", {}),
        ):
            with self.subTest(status=status, headers=headers):
                self.fail_download = lambda request: httpx.Response(
                    status, stream=httpx.ByteStream(body), headers=headers
                )
                with self.assertRaises(KindleError):
                    download_book(self.client, self.item, self.root)
                self.assertFalse(list(self.root.glob("*/*/receipt.json")))

    def test_wrong_content_id_is_not_downloaded(self):
        self.manifest["content"]["id"] = "different-book"
        with self.assertRaises(KindleError) as failure:
            download_book(self.client, self.item, self.root)
        self.assertEqual(failure.exception.code, "manifest_shape")
        self.assertEqual(len(self.requests), 1)

    def test_corrupted_cached_resource_can_be_downloaded_again(self):
        directory, _ = download_book(self.client, self.item, self.root)
        resource = read_json(directory / "receipt.json")["resources"][0]
        (directory / resource["file"]).write_bytes(b"corrupt")
        again, result = download_book(self.client, self.item, self.root)
        self.assertEqual(again, directory)
        self.assertEqual(result["state"], "importable")
        self.assertEqual((again / resource["file"]).read_bytes(), self.body)
        self.assertFalse(list(self.root.glob("*/.replaced-*")))

    def test_old_pdoc_uses_read_only_delivery_when_modern_manifest_is_404(self):
        requests = []

        def handle(request):
            requests.append(request)
            if "/delivery/manifest/" in request.url.path:
                return httpx.Response(404)
            self.assertEqual(request.url.host, "cde-ta-g7g.amazon.com")
            self.assertEqual(request.url.params["type"], "PDOC")
            self.assertEqual(request.url.params["key"], self.item["id"])
            self.assertIn("x-adp-token", request.headers)
            return httpx.Response(200, stream=httpx.ByteStream(self.body))

        client = KindleClient(
            MemoryVault(synthetic_session()), transport=httpx.MockTransport(handle)
        )
        try:
            _, result = download_book(client, self.item, self.root)
            self.assertEqual(result["state"], "importable")
            self.assertEqual(len(requests), 2)
        finally:
            client.close()

    def test_cookie_from_service_is_not_forwarded_to_cdn(self):
        self.manifest["resources"][0].pop("optimalEndpoint")

        def handle(request):
            if request.url.host == "kindle-digital-delivery.amazon.com":
                return httpx.Response(
                    302,
                    headers={
                        "location": "https://cdn.amazon.com/book",
                        "set-cookie": "session=PRIVATE; Domain=.amazon.com; Path=/",
                    },
                )
            self.assertNotIn("cookie", request.headers)
            return httpx.Response(200, stream=httpx.ByteStream(self.body))

        self.fail_download = handle
        download_book(self.client, self.item, self.root)

    def test_valid_converter_output_is_checked_before_being_importable(self):
        self.body = b"\0" * 60 + b"BOOKMOBI" + b"synthetic-unsupported"
        directory, _ = download_book(self.client, self.item, self.root)

        def convert(arguments, **kwargs):
            self.assertFalse(kwargs["shell"])
            Path(arguments[2]).write_bytes(synthetic_epub())
            return type("Result", (), {"returncode": 0})()

        with (
            patch(
                "tool.kindle_personal.prepare.find_converter",
                return_value="test-converter",
            ),
            patch("tool.kindle_personal.prepare.subprocess.run", side_effect=convert),
        ):
            result = prepare_download(directory, convert=True)
        self.assertEqual(result["state"], "importable")
        self.assertFalse(result["opened_in_kmreader"])

    def test_duplicate_resources_and_unsupported_method_fail_before_transfers(self):
        self.manifest["resources"].append(dict(self.manifest["resources"][0]))
        with self.assertRaises(KindleError):
            download_book(self.client, self.item, self.root)
        self.assertFalse(self.seen_content)
        self.manifest["resources"].pop()
        self.manifest["resources"][0]["endpoint"]["httpMethod"] = "POST"
        with self.assertRaises(KindleError):
            download_book(self.client, self.item, self.root)

    def test_converter_failure_does_not_claim_readability(self):
        self.body = b"\0" * 60 + b"BOOKMOBI" + b"synthetic-unsupported"
        directory, result = download_book(self.client, self.item, self.root)
        self.assertEqual(result["state"], "needs_conversion")
        with (
            patch(
                "tool.kindle_personal.prepare.find_converter",
                return_value="test-converter",
            ),
            patch(
                "tool.kindle_personal.prepare.subprocess.run",
                return_value=type("Result", (), {"returncode": 1})(),
            ),
        ):
            result = prepare_download(directory, convert=True)
        self.assertEqual(result["state"], "needs_conversion")
        self.assertEqual(result["reason"], "conversion_unsupported")
        self.assertFalse((directory / "ready.epub").exists())


class FormatAndPrivacyTest(unittest.TestCase):
    def test_url_allowlist_rejects_downgrade_credentials_and_lookalikes(self):
        for url in (
            "http://content.amazon.com/file",
            "https://amazon.com.evil.example/file",
            "https://user:password@amazon.com/file",
            "https://127.0.0.1/file",
            "https://content.amazon.com:444/file",
        ):
            with self.subTest(url=url), self.assertRaises(KindleError):
                check_url(url)
        check_url("https://content.amazon.com/file?temporary=private")

    def test_native_epub_and_pdf_and_encrypted_pdf(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "file"
            for content, expected in (
                (synthetic_epub(), True),
                (synthetic_pdf(), True),
                (synthetic_pdf(encrypted=True), False),
            ):
                path.write_bytes(content)
                self.assertEqual(inspect_file(path)["importable"], expected)

    def test_account_namespaces_do_not_mix_accounts(self):
        self.assertNotEqual(
            account_key({"customer_id": "one"}), account_key({"customer_id": "two"})
        )
        self.assertNotIn("one", account_key({"customer_id": "one"}))

    def test_shared_diagnostic_excludes_book_titles_ids_tokens_and_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            client = KindleClient(MemoryVault(synthetic_session()))
            try:
                app = Application(directory, client=client)
                write_json(
                    app.account_directory / "catalog.json",
                    {"complete": True, "items": [{"title": "PRIVATE_TITLE"}]},
                )
                with redirect_stdout(io.StringIO()):
                    report = app.report()
                data = json.dumps(report)
                for secret in (
                    "PRIVATE_TITLE",
                    "synthetic-adp",
                    "synthetic-access",
                    "synthetic-customer",
                    "PRIVATE KEY",
                    str(directory),
                ):
                    self.assertNotIn(secret, data)
            finally:
                client.close()

    def test_complete_synthetic_pipeline(self):
        report = self_check()
        self.assertFalse(report["amazon_contacted"])
        self.assertEqual(
            report["download_and_prepare"], {"EBOK": "epub", "PDOC": "pdf"}
        )

    def test_operation_lock_blocks_second_instance(self):
        with tempfile.TemporaryDirectory() as temporary:
            with exclusive(Path(temporary)):
                with self.assertRaises(KindleError):
                    with exclusive(Path(temporary)):
                        self.fail("Second instance must not enter")


if __name__ == "__main__":
    unittest.main()
