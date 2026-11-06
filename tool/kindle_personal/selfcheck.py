"""Offline executable smoke check with synthetic EBOK/PDOC and Windows DPAPI."""

import io
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
from .common import atomic_bytes


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
            client.register(
                LoginAttempt("SYNTHETIC"), {"authorization_code": "synthetic-code"}
            )
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
            instance = playwright.chromium.launch(
                headless=True, channel="msedge" if os.name == "nt" else None
            )
            try:
                context = instance.new_context(service_workers="block")
                attempt = LoginAttempt("synthetic-browser")
                callback = "https://www.amazon.it/ap/maplanding?" + urlencode(
                    {
                        "openid.oa2.authorization_code": "synthetic-browser-code",
                        "openid.oa2.state": attempt.state,
                    }
                )
                context.route(
                    "**/*",
                    lambda route: route.fulfill(
                        content_type="text/html",
                        body=f"<script>location.href={callback!r};</script>",
                    ),
                )
                assert (
                    capture_in_context(context, attempt, timeout=5)[
                        "authorization_code"
                    ]
                    == "synthetic-browser-code"
                )
                context.close()
            finally:
                instance.close()
        report["browser_callback"] = "passed"
    return report
