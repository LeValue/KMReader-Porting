"""Offline executable smoke check with synthetic EBOK/PDOC and Windows DPAPI."""

import io
import json
import os
import tempfile
import time
import zipfile
from pathlib import Path

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from . import VERSION
from .auth import LoginAttempt
from .catalog import synchronize, visible_items
from .client import CATALOG_URL, KindleClient
from .download import download_book, _context
from .prepare import prepare_download
from .storage import WindowsVault
from .common import atomic_bytes, file_hash, write_json


def synthetic_kfx():
    """Generate a tiny CONT container from our own text, never a user book."""
    import logging
    from kfxlib import YJ_Book, set_logger
    from kfxlib.kfx_container import KfxContainer
    from kfxlib.yj_container import YJFragment

    logger = logging.Logger("synthetic-kfx", level=logging.CRITICAL + 1)
    logger.addHandler(logging.NullHandler())
    set_logger(logger)
    with tempfile.TemporaryDirectory() as temporary:
        source = Path(temporary) / "book.ion"
        source.write_text(
            "'$258'::{ '$153':\"KMReader synthetic KFX\", '$10':\"it\", "
            "'$251':\"PDOC\", '$169':[{ '$178':'$351', '$170':['section_1'] }] }\n"
            "'section_1'::'$260'::{ '$174':'section_1', "
            "'$141':[{ '$159':'$270', '$156':'$323', '$176':'story_1' }] }\n"
            "'story_1'::'$259'::{ '$176':'story_1', "
            "'$146':[{ '$159':'$269', '$145':\"Questo documento sintetico "
            'verifica la conversione KFX in EPUB." }] }\n',
            encoding="utf-8",
        )
        book = YJ_Book(str(source))
        book.decode_book()
        for symbol in ("section_1", "story_1"):
            book.symtab.create_local_symbol(symbol)
        book.fragments.append(YJFragment(book.symtab.create_import()))
        return KfxContainer(book.symtab, fragments=book.fragments).serialize()


def synthetic_epub():
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip")
        archive.writestr(
            "META-INF/container.xml",
            '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
        )
        archive.writestr(
            "OPS/book.opf",
            '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">synthetic</dc:identifier>'
            "<dc:title>KMReader synthetic Kindle test</dc:title><dc:language>it</dc:language></metadata>"
            '<manifest><item id="text" href="text.xhtml" media-type="application/xhtml+xml"/></manifest>'
            '<spine><itemref idref="text"/></spine></package>',
        )
        archive.writestr(
            "OPS/text.xhtml",
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Test</title></head>'
            "<body><h1>Prova locale</h1><p>Questo testo non proviene da Amazon.</p></body></html>",
        )
    return output.getvalue()


def synthetic_pdf(*, encrypted=False):
    from pypdf import PdfWriter

    writer = PdfWriter()
    writer.add_blank_page(width=300, height=400)
    if encrypted:
        writer.encrypt("test-only")
    output = io.BytesIO()
    writer.write(output)
    return output.getvalue()


class MemoryVault:
    """Test-only, never selected by the interactive program."""

    def __init__(self, session=None):
        self.session = session

    def load(self):
        return self.session

    def save(self, value):
        self.session = value

    def clear(self):
        self.session = None


def synthetic_session():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return {
        "marketplace": "amazon.it",
        "customer_id": "synthetic-customer",
        "serial": "SYNTHETIC",
        "device_type": "TEST",
        "profile": "test",
        "flow": "pkce",
        "expires": time.time() + 3600,
        "adp_token": "synthetic-adp",
        "access_token": "synthetic-access",
        "refresh_token": "synthetic-refresh",
        "device_private_key": key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ).decode(),
    }


def self_check(*, browser=False, fixtures=None):
    session = synthetic_session()
    report = {"schema": 1, "prototype_version": VERSION, "amazon_contacted": False}
    with tempfile.TemporaryDirectory(prefix="kmreader-kindle-selftest-") as temporary:
        root = Path(temporary)
        if os.name == "nt":
            vault = WindowsVault(root)
            vault.save(session)
            assert vault.load() == session
            encrypted = vault.path.read_bytes()
            assert b"synthetic-adp" not in encrypted and b"PRIVATE KEY" not in encrypted
            vault.clear()
            assert vault.load() is None
            report["windows_dpapi"] = "passed"
        else:
            report["windows_dpapi"] = "not_this_platform"
        epub, pdf = synthetic_epub(), synthetic_pdf()
        catalog = (
            b"<response><sync_time>synthetic-time</sync_time><add_update_list>"
            b"<meta_data><ASIN>TEST-EBOK</ASIN><cde_contenttype>EBOK</cde_contenttype><title>Romanzo sintetico</title></meta_data>"
            b"<meta_data><ASIN>opaque-Pdoc-Id</ASIN><cde_contenttype>PDOC</cde_contenttype><title>Documento sintetico</title></meta_data>"
            b"<meta_data><ASIN>FREE-DICT</ASIN><cde_contenttype>EBOK</cde_contenttype><title>Dizionario sintetico</title><content_tags><tag>DICT</tag><tag>FREE_DICT</tag></content_tags></meta_data>"
            b"</add_update_list></response>"
        )

        def handle(request):
            if request.url.path == "/auth/register":
                body = json.loads(request.content)
                assert body["cookies"] == {
                    "website_cookies": [],
                    "domain": ".amazon.it",
                }
                assert set(body["requested_token_type"]) == {
                    "bearer",
                    "mac_dms",
                    "website_cookies",
                    "store_authentication_cookie",
                }
                assert (
                    body["auth_data"]["authorization_code"]
                    == "synthetic+code/part+value"
                )
                assert body["auth_data"]["client_id"] == attempt.client_id
                assert body["auth_data"]["code_verifier"] == attempt.verifier
                return httpx.Response(
                    200,
                    json={
                        "response": {
                            "success": {
                                "tokens": {
                                    "bearer": {
                                        "access_token": session["access_token"],
                                        "refresh_token": session["refresh_token"],
                                        "expires_in": 3600,
                                    },
                                    "mac_dms": {
                                        "adp_token": session["adp_token"],
                                        "device_private_key": session[
                                            "device_private_key"
                                        ],
                                    },
                                    "website_cookies": [
                                        {
                                            "Name": "session-id",
                                            "Value": "PRIVATE_BROWSER_COOKIE",
                                        }
                                    ],
                                    "store_authentication_cookie": {
                                        "token": "PRIVATE_STORE_COOKIE"
                                    },
                                },
                                "extensions": {
                                    "customer_info": {"user_id": session["customer_id"]}
                                },
                            },
                        }
                    },
                )
            if str(request.url).startswith(CATALOG_URL):
                assert "x-adp-signature" in request.headers
                return httpx.Response(200, content=catalog)
            if "/delivery/manifest/" in request.url.path:
                identifier = request.url.path.rsplit("/", 1)[-1]
                return httpx.Response(
                    200,
                    json={
                        "content": {"id": identifier},
                        "resources": [
                            {
                                "id": identifier,
                                "type": "KINDLE_MAIN_BASE",
                                "requirement": "REQUIRED",
                                "optimalEndpoint": {
                                    "directUrl": f"https://synthetic.cloudfront.net/{identifier}"
                                },
                            },
                            {
                                "id": identifier + "-notes",
                                "type": "KINDLE_USER_ANOT",
                                "requirement": "DEFERRED",
                                "optimalEndpoint": {
                                    "directUrl": f"https://synthetic.cloudfront.net/{identifier}-notes"
                                },
                            },
                        ],
                    },
                )
            if request.url.host == "synthetic.cloudfront.net":
                assert "x-adp-token" not in request.headers
                assert "authorization" not in request.headers
                if request.url.path.endswith("-notes"):
                    return httpx.Response(
                        200,
                        stream=httpx.ByteStream(
                            b'<response><book><bookmark begin="1"/></book></response>'
                        ),
                        headers={"content-type": "application/xml"},
                    )
                return httpx.Response(
                    200,
                    stream=httpx.ByteStream(
                        epub if request.url.path == "/TEST-EBOK" else pdf
                    ),
                )
            raise AssertionError("Unexpected synthetic endpoint")

        vault = MemoryVault()
        client = KindleClient(vault, transport=httpx.MockTransport(handle))
        directories = []
        try:
            attempt = LoginAttempt("SYNTHETIC")
            assert "openid.assoc_handle=amzn_device_it" in attempt.url()
            assert "pageId=amzn_device_common_dark" in attempt.url()
            auth_data = attempt.callback(
                "https://www.amazon.it/ap/maplanding?openid.oa2.authorization_code=synthetic+code/part%2Bvalue"
            )
            client.register(attempt, auth_data)
            assert "PRIVATE_BROWSER_COOKIE" not in json.dumps(vault.session)
            assert "PRIVATE_STORE_COOKIE" not in json.dumps(vault.session)
            report["device_entry_contract"] = "passed"
            report["opaque_credentials"] = "passed"
            snapshot = synchronize(client, full=True)
            assert snapshot["complete"] and len(snapshot["items"]) == 3
            assert len(visible_items(snapshot)) == 2
            report["catalog_dictionary_filter"] = "passed"
            outputs = {}
            for item in visible_items(snapshot):
                directory, prepared = download_book(client, item, root / "books")
                assert prepared["state"] == "importable"
                assert prepared["opened_in_kmreader"] is False
                assert (directory / prepared["file"]).is_file()
                outputs[item["type"]] = prepared["format"]
                if fixtures is not None:
                    atomic_bytes(
                        Path(fixtures)
                        / ("synthetic-" + item["type"] + "." + prepared["format"]),
                        (directory / prepared["file"]).read_bytes(),
                    )
                directories.append(directory)
                receipt = (directory / "receipt.json").read_text()
                assert '"payload_kind": "xml"' in receipt
                assert (
                    "synthetic.cloudfront.net" not in receipt
                    and "synthetic-adp" not in receipt
                )
            report.update(
                registration="passed",
                signed_catalog="passed",
                download_and_prepare=outputs,
                structured_resources="passed",
            )
        finally:
            client.close()
        for directory in directories:
            assert prepare_download(directory)["state"] == "importable"
        report["offline_reopen"] = "passed"
        kfx_directory = root / "offline-kfx"
        kfx_directory.mkdir()
        source = kfx_directory / "0000-document.azw"
        source.write_bytes(synthetic_kfx())
        write_json(
            kfx_directory / "receipt.json",
            {
                "download_state": "complete",
                "resources": [
                    {
                        "file": source.name,
                        "bytes": source.stat().st_size,
                        "sha256": file_hash(source),
                        "type": "KINDLE_MAIN_BASE",
                    }
                ],
            },
        )
        prepared = prepare_download(kfx_directory, convert=True)
        assert prepared["state"] == "importable"
        with zipfile.ZipFile(kfx_directory / prepared["file"]) as archive:
            assert any(
                b"Questo documento sintetico" in archive.read(name)
                for name in archive.namelist()
                if name.endswith(".xhtml")
            )
        if fixtures is not None:
            atomic_bytes(
                Path(fixtures) / "synthetic-KFX.epub",
                (kfx_directory / prepared["file"]).read_bytes(),
            )
        assert prepare_download(kfx_directory)["state"] == "importable"
        report["offline_kfx_conversion"] = "passed"
        import base64

        assert (
            _context(base64.b64encode(b'{transport:"WiFi"}').decode())["transport"]
            == "WiFi"
        )
        report["ion_context"] = "passed"
    if browser:
        from urllib.parse import urlencode
        from playwright.sync_api import sync_playwright
        from .browser import capture_in_context

        with sync_playwright() as playwright:
            for channel in ["msedge", "chrome"] if os.name == "nt" else [None]:
                instance = playwright.chromium.launch(headless=True, channel=channel)
                try:
                    context = instance.new_context(service_workers="block")
                    attempt = LoginAttempt("synthetic-browser")
                    callback = "https://www.amazon.it/ap/maplanding?" + urlencode(
                        {
                            "openid.ns": "http://specs.openid.net/auth/2.0",
                            "openid.oa2.authorization_code": "synthetic+/browser-code",
                            "openid.oa2.state": attempt.state,
                        },
                        safe="/+",
                    )
                    forwarded, redeemed = [], []

                    def upstream(route):
                        if "/ap/signin?" not in route.request.url:
                            forwarded.append(True)
                        route.fulfill(
                            content_type="text/html",
                            body=f"<script>location.href={callback!r};</script>",
                        )

                    context.route("**/*", upstream)
                    assert (
                        capture_in_context(
                            context, attempt, timeout=5, on_auth=redeemed.append
                        )["authorization_code"]
                        == "synthetic+/browser-code"
                    )
                    assert not forwarded and len(redeemed) == 1
                    assert not context.pages[0].is_closed()
                    context.close()
                finally:
                    instance.close()
                report[
                    "browser_callback_"
                    + (
                        "edge"
                        if channel == "msedge"
                        else "chrome"
                        if channel == "chrome"
                        else "chromium"
                    )
                ] = "passed"
        report["browser_callback"] = "passed"
        report["browser_callback_interception"] = "passed"
        report["browser_auth_handler"] = "passed"
    return report
