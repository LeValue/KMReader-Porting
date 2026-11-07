"""Small, deliberately credential-free records and filesystem helpers."""

import hashlib
import json
import os
import tempfile
from pathlib import Path

AUTH_ERROR_REASONS = {
    "invalid_grant",
    "expired_token",
    "invalid_authentication_data",
    "invalid_request",
    "invalid_client",
    "unauthorized_client",
    "invalid_scope",
    "unsupported_grant_type",
    "access_denied",
    "invalid_token",
    "invalid_device",
    "device_registration_limit_exceeded",
    "device_already_registered",
    "validation_error",
    "unknown",
}


class KindleError(Exception):
    """Only public diagnostics belong in this exception (never response bodies)."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        stage: str = "local",
        status=None,
        details=None,
        authentication=None,
    ):
        super().__init__(message)
        self.code, self.stage, self.status = code, stage, status
        self.details = {}
        self.add_details(details or {})
        self.authentication = {}
        self.add_authentication(authentication or {})

    def add_authentication(self, details):
        categories = {
            "reason": AUTH_ERROR_REASONS,
            "flow": {"pkce", "token"},
            "response_format": {"json", "other", "empty"},
            "entry": {"device_it", "kindle_ios_it"},
            "browser": {"chrome", "msedge"},
        }
        for key, value in details.items():
            if (
                key in categories
                and isinstance(value, str)
                and value in categories[key]
            ):
                self.authentication[key] = value

    def add_details(self, details):
        # Diagnostics accept protocol categories and counters, never arbitrary
        # response strings, content IDs, URLs, tokens, titles or response bodies.
        categories = {
            "resource_type": {
                "KINDLE_MAIN_BASE",
                "KINDLE_MAIN_METADATA",
                "KINDLE_MAIN_ATTACHABLE",
                "KINDLE_USER_ANOT",
                "DRM_VOUCHER",
                "OTHER",
            },
            "payload_kind": {"binary", "json", "xml", "html", "empty", "unknown"},
            "book_type": {"EBOK", "PDOC"},
        }
        for key, value in details.items():
            if (
                key in categories
                and isinstance(value, str)
                and value in categories[key]
            ):
                self.details[key] = value
            elif (
                key in {"resource_index", "resource_count"}
                and type(value) is int
                and 0 < value <= 4096
            ):
                self.details[key] = value

    def diagnostic(self):
        result = {"code": self.code, "stage": self.stage, "http_status": self.status}
        if self.details:
            result["resource"] = self.details
        if self.authentication:
            result["authentication"] = self.authentication
        return result


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def atomic_bytes(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def write_json(path: Path, value):
    atomic_bytes(
        path, (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()
    )


def read_json(path: Path, default=None):
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        raise KindleError("local_record", "Record locale non leggibile.") from None


def file_hash(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()
