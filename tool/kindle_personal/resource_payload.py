"""Distinguish structured Kindle resources from HTTP-200 service error pages.

Kindle notes and metadata can legitimately be XML/JSON. MIME alone cannot
classify them as failures. Payloads are checked locally; none enter diagnostics.
"""

import json

from defusedxml import ElementTree as ET
from defusedxml.common import DefusedXmlException

from .common import KindleError

STRUCTURED_RESOURCES = {"KINDLE_MAIN_METADATA", "KINDLE_USER_ANOT"}
MAX_STRUCTURED = 8 * 1024 * 1024


def _json_error(value):
    if not isinstance(value, dict):
        return False
    if any(
        value.get(key) not in (None, False, "", [], {})
        for key in ("error", "errors", "errorCode")
    ):
        return True
    if isinstance(value.get("__type"), str) and value["__type"].lower().endswith(
        ("error", "exception")
    ):
        return True
    if value.get("success") is False or str(value.get("status", "")).casefold() in (
        "error",
        "failed",
        "failure",
    ):
        return True
    if (
        "code" in value
        and ("message" in value or "Message" in value)
        and not any(key in value for key in ("metadata", "annotations", "book"))
    ):
        return True
    response = value.get("response")
    return isinstance(response, dict) and _json_error(response)


def validate_resource(path, *, resource_type, content_type, status):
    with path.open("rb") as stream:
        prefix = stream.read(512)
    text = prefix.lstrip(b"\xef\xbb\xbf \t\r\n").lower()
    binary_magic = (
        prefix.startswith(
            (b"PK\x03\x04", b"%PDF-", b"\xeaDRMION\xee", b"\xe0\x01\x00\xea")
        )
        or prefix[60:68] == b"BOOKMOBI"
    )
    if binary_magic:
        kind = "binary"
    elif content_type == "text/html" or text.startswith((b"<!doctype html", b"<html")):
        kind = "html"
    elif "json" in content_type or text.startswith((b"{", b"[")):
        kind = "json"
    elif "xml" in content_type or text.startswith(b"<"):
        kind = "xml"
    else:
        kind = "binary"

    def fail(code="resource_error_page"):
        raise KindleError(
            code,
            "Risposta della risorsa Kindle non valida; controlla la diagnostica per tipo e stato HTTP.",
            stage="download",
            status=status,
            details={"payload_kind": kind},
        )

    if kind == "html":
        fail()
    if kind in {"json", "xml"}:
        if resource_type not in STRUCTURED_RESOURCES:
            fail()
        if path.stat().st_size > MAX_STRUCTURED:
            fail("resource_metadata_size")
        raw = path.read_bytes()
        if kind == "json":
            try:
                value = json.loads(raw)
            except (ValueError, UnicodeError):
                fail("resource_payload_invalid")
            if not isinstance(value, (dict, list)):
                fail("resource_payload_invalid")
            if _json_error(value):
                fail("resource_service_error")
        else:
            try:
                root = ET.fromstring(raw)
            except (ET.ParseError, DefusedXmlException):
                fail("resource_payload_invalid")
            name = root.tag.rsplit("}", 1)[-1].casefold()
            if name in {"html", "error", "errors", "errorresponse", "exception"}:
                fail("resource_service_error")
            if name == "response" and any(
                e.tag.rsplit("}", 1)[-1].casefold() in {"error", "errors", "exception"}
                for e in root
            ):
                fail("resource_service_error")
    return kind
