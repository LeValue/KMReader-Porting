"""Private Windows IPC for the opt-in STK probe; never print session values."""

import argparse
import json
import sys
import re
import urllib.request
import urllib.error
import urllib.parse
from http.cookies import SimpleCookie
from pathlib import Path

from tool.kindle_personal.storage import WindowsVault, default_directory


def website_probe(output):
    """Check first-party web STK access from the reader's existing refresh token."""
    report = {"schema": 1, "kind": "website_session", "document_uploads": 0,
              "document_deletions": 0, "annotation_writes": 0}

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None

    opener = urllib.request.build_opener(NoRedirect())
    cookies = {}

    def request(stage, path, data=None, extra_headers=None):
        headers = {"User-Agent": "Mozilla/5.0", "Accept": "application/json"}
        if cookies:
            headers["Cookie"] = "; ".join(f"{k}={v}" for k, v in cookies.items())
        if isinstance(data, dict):
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            data = urllib.parse.urlencode(data).encode()
        headers.update(extra_headers or {})
        req = urllib.request.Request("https://www.amazon.it" + path,
                                     data=data, headers=headers)
        try:
            with opener.open(req, timeout=45) as response:
                body = response.read(4 * 1024 * 1024 + 1)
                if len(body) > 4 * 1024 * 1024:
                    raise ValueError("response_size")
                report[stage] = {"http_status": response.status}
                for value in response.headers.get_all("Set-Cookie", []):
                    parsed = SimpleCookie(value)
                    for name, cookie in parsed.items():
                        cookies[name] = cookie.value
                return body
        except urllib.error.HTTPError as error:
            report[stage] = {"http_status": error.code}
            location = urllib.parse.urlsplit(error.headers.get("Location", ""))
            report[stage]["redirect_host"] = location.hostname if location.hostname in ("www.amazon.it", "www.amazon.com") else "other"
            report[stage]["redirect_path"] = location.path if location.path in ("/ap/signin", "/sendtokindle", "/sendtokindle/get-device-list", "/sendtokindle/login") else "other"
            raise ValueError("website_request") from None

    try:
        session = WindowsVault(default_directory()).load()
        if not session or not session.get("refresh_token"):
            raise ValueError("session_missing")
        body = request("cookie_exchange", "/ap/exchangetoken/cookies", {
            "app_name": "Kindle for iOS", "app_version": "6.38.0.100",
            "source_token": session["refresh_token"],
            "source_token_type": "refresh_token",
            "requested_token_type": "auth_cookies", "domain": ".amazon.it",
        })
        value = json.loads(body)
        raw = value.get("response", {}).get("tokens", {}).get("cookies", {})
        for domain, entries in raw.items():
            if domain not in (".amazon.it", "amazon.it", ".www.amazon.it", "www.amazon.it"):
                continue
            for cookie in entries:
                name, value = cookie.get("Name", ""), cookie.get("Value", "")
                if re.fullmatch(r"[A-Za-z0-9_-]+", name) and not re.search(r"[;\r\n\x00]", value):
                    cookies[name] = value
        report["cookie_exchange"]["cookie_count"] = len(cookies)
        if not cookies:
            raise ValueError("website_cookies")
        auth = json.loads(request("authentication", "/sendtokindle/extension/checkAuth"))
        report["authenticated"] = auth.get("isAuthed") is True
        if not report["authenticated"]:
            raise ValueError("website_not_authenticated")
        page = request("csrf", "/sendtokindle/empty").decode("utf-8")
        report["csrf_available"] = bool(re.search(r'''name=['"]csrfToken['"]\s+value=['"]([^'"\r\n]+)['"]''', page))
        token = re.search(r'''name=['"]csrfToken['"]\s+value=['"]([^'"\r\n]+)['"]''', page)
        if token:
            request("devices", "/sendtokindle/get-device-list", json.dumps({"extName": "chrome_ocs", "extVersion": "1.0"}).encode(),
                    {"Content-Type": "application/json", "anti-csrftoken-a2z": token.group(1), "Origin": "https://www.amazon.it", "Referer": "https://www.amazon.it/sendtokindle"})
        report["passed"] = report["csrf_available"]
    except Exception:
        report["passed"] = False
    finally:
        output.write_text(json.dumps(report), encoding="utf-8")
    return 0 if report["passed"] else 2


def transfer(operation, path):
    existing = WindowsVault(default_directory()).load()
    if not existing or not existing.get("customer_id"):
        raise ValueError("session_missing")
    cache = WindowsVault(default_directory().parent / "KindleSendProbe")
    if operation == "export":
        cached = cache.load()
        session = dict(existing)
        if cached and cached.get("customer_id") == existing["customer_id"]:
            if cached.get("send_device"):
                session["send_device"] = cached["send_device"]
        payload = {"session": session}
        if cached and cached.get("customer_id") == existing["customer_id"] and cached.get("probe_operation"):
            payload["probe_operation"] = cached["probe_operation"]
        path.write_text(json.dumps(payload), encoding="utf-8")
    else:
        payload = json.loads(path.read_text(encoding="utf-8"))
        session = payload["session"]
        if session.get("customer_id") != existing["customer_id"]:
            raise ValueError("account_mismatch")
        record = cache.load() or {}
        if record.get("customer_id") != existing["customer_id"]:
            record = {"customer_id": existing["customer_id"]}
        device = session.get("send_device", {})
        if device.get("adp_token") and device.get("device_private_key"):
            record["send_device"] = device
        if payload.get("probe_operation"):
            record["probe_operation"] = payload["probe_operation"]
        if record.get("send_device") or record.get("probe_operation"):
            cache.save(record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("export", "seal", "web-check"))
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    if args.operation == "web-check":
        return website_probe(args.path)
    try:
        transfer(args.operation, args.path)
    except Exception:
        # DPAPI, file paths and session records must not enter Actions logs.
        print("Kindle probe private session unavailable.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
