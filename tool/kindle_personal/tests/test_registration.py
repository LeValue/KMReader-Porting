import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import MagicMock, patch

import httpx

from tool.kindle_personal.auth import (
    LoginAttempt,
    registration_body,
    registration_error_reason,
)
from tool.kindle_personal.browser import capture_login
from tool.kindle_personal.cli import Application
from tool.kindle_personal.client import KindleClient
from tool.kindle_personal.common import KindleError
from tool.kindle_personal.selfcheck import MemoryVault, synthetic_session


class RegistrationErrorTest(unittest.TestCase):
    def test_browser_preference_defaults_to_chrome_and_is_saved_for_next_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            client = MagicMock()
            client.session = None
            app = Application(Path(temporary), client=client)
            self.assertEqual(app.login_browser, "chrome")
            app.set_login_browser("msedge")
            restored = Application(Path(temporary), client=client)
            self.assertEqual(restored.login_browser, "msedge")
            with (
                patch("tool.kindle_personal.browser.capture_login") as browser,
                redirect_stdout(io.StringIO()),
            ):
                restored.login()
                self.assertEqual(browser.call_args.kwargs["channel"], "msedge")
                restored.login(browser="chrome")
                self.assertEqual(browser.call_args.kwargs["channel"], "chrome")
            self.assertEqual(restored.login_browser, "msedge")

    def test_browser_choice_does_not_modify_identity_or_credentials(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = synthetic_session()
            vault = MemoryVault(session)
            client = KindleClient(vault)
            try:
                directory = Path(temporary)
                identity = directory / "identity.json"
                identity.write_text('{"serial":"stable"}')
                app = Application(directory, client=client)
                app.set_login_browser("chrome")
                self.assertEqual(identity.read_text(), '{"serial":"stable"}')
                self.assertIs(vault.session, session)
            finally:
                client.close()

    def test_existing_legacy_session_is_preserved_without_opening_login(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = synthetic_session()
            session["profile"] = "kindle-ios-6.38-experimental"
            vault = MemoryVault(session)
            client = KindleClient(vault)
            try:
                with (
                    patch("tool.kindle_personal.browser.capture_login") as login,
                    redirect_stdout(io.StringIO()),
                ):
                    app = Application(Path(temporary), client=client)
                    app.login()
                    report = app.report()
                login.assert_not_called()
                self.assertIs(vault.session, session)
                self.assertEqual(report["profile"], session["profile"])
            finally:
                client.close()

    def test_opaque_credentials_preserve_raw_plus_and_decode_percent_once(self):
        for flow, key in (("pkce", "authorization_code"), ("token", "access_token")):
            for separator in ("?", "#"):
                with self.subTest(flow=flow, separator=separator):
                    attempt = LoginAttempt("synthetic", flow)
                    result = attempt.callback(
                        "https://www.amazon.it/ap/maplanding"
                        + separator
                        + "openid.oa2."
                        + key
                        + "=synthetic+raw/part%2Bencoded%252F&openid.oa2.state="
                        + attempt.state
                    )
                    self.assertEqual(result[key], "synthetic+raw/part+encoded%2F")

    def test_registration_uses_the_complete_device_contract_without_browser_cookies(
        self,
    ):
        attempt = LoginAttempt("synthetic-stable-serial")
        data = attempt.callback(
            "https://www.amazon.it/ap/maplanding?openid.oa2.authorization_code=synthetic+code"
        )
        body = registration_body(attempt, data)
        self.assertEqual(
            body["cookies"], {"website_cookies": [], "domain": ".amazon.it"}
        )
        self.assertEqual(
            set(body["requested_token_type"]),
            {"bearer", "mac_dms", "website_cookies", "store_authentication_cookie"},
        )
        self.assertEqual(body["auth_data"]["authorization_code"], "synthetic+code")
        self.assertEqual(body["auth_data"]["client_id"], attempt.client_id)
        self.assertEqual(body["auth_data"]["code_verifier"], attempt.verifier)
        self.assertEqual(body["registration_data"]["device_serial"], attempt.serial)
        self.assertIn("%DUPE_STRATEGY_1ST%", body["registration_data"]["device_name"])

    def test_empty_duplicate_or_whitespace_credentials_are_not_registered(self):
        attempt = LoginAttempt("synthetic")
        for query in (
            "openid.oa2.authorization_code=",
            "openid.oa2.authorization_code=&openid.oa2.authorization_code=valid",
            "openid.oa2.authorization_code=with%20space",
        ):
            with self.subTest(query=query), self.assertRaises(KindleError):
                attempt.callback("https://www.amazon.it/ap/maplanding?" + query)

    def test_known_protocol_reasons_are_classified_without_copying_messages(self):
        for payload, expected in [
            (
                {"error": "invalid_grant", "error_description": "SECRET_CODE"},
                "invalid_grant",
            ),
            (
                {
                    "response": {
                        "error": {
                            "code": "InvalidAuthenticationData",
                            "message": "SECRET",
                        }
                    }
                },
                "invalid_authentication_data",
            ),
            ({"__type": "com.amazon.identity#InvalidRequest"}, "invalid_request"),
            (
                {"error": {"code": "DeviceRegistrationLimitExceeded"}},
                "device_registration_limit_exceeded",
            ),
            ({"response": {"error": {"code": "PRIVATE_CUSTOMER_ID"}}}, "unknown"),
            (
                {
                    "response": {
                        "errors": [{"Code": "InvalidAuthData", "Message": "SECRET"}]
                    }
                },
                "invalid_authentication_data",
            ),
        ]:
            with self.subTest(expected=expected):
                self.assertEqual(registration_error_reason(payload), expected)

    def test_register_400_is_not_retried_and_keeps_only_a_known_reason(self):
        seen = []

        def handle(request):
            seen.append(request)
            return httpx.Response(
                400,
                json={
                    "response": {
                        "error": {
                            "code": "InvalidAuthenticationData",
                            "message": "PRIVATE_TOKEN PRIVATE_CUSTOMER",
                        }
                    }
                },
            )

        vault = MemoryVault()
        client = KindleClient(vault, transport=httpx.MockTransport(handle))
        try:
            with self.assertRaises(KindleError) as failed:
                client.register(
                    LoginAttempt("synthetic"), {"authorization_code": "PRIVATE_CODE"}
                )
            record = failed.exception.diagnostic()
            self.assertEqual(record["http_status"], 400)
            self.assertEqual(record["stage"], "register")
            self.assertEqual(
                record["authentication"],
                {
                    "reason": "invalid_authentication_data",
                    "response_format": "json",
                    "flow": "pkce",
                    "entry": "device_it",
                },
            )
            self.assertNotIn("PRIVATE", json.dumps(record))
            self.assertEqual(len(seen), 1)
            self.assertIsNone(vault.session)
        finally:
            client.close()

    def test_non_json_400_and_unknown_codes_do_not_leak_response_text(self):
        for body, mime in [
            (b"<html>PRIVATE_SESSION</html>", "text/html"),
            (
                b'{"error":{"code":"PRIVATE_SESSION","message":"PRIVATE_CODE"}}',
                "application/json",
            ),
        ]:
            with self.subTest(mime=mime):
                client = KindleClient(
                    MemoryVault(),
                    transport=httpx.MockTransport(
                        lambda request: httpx.Response(
                            400, content=body, headers={"content-type": mime}
                        )
                    ),
                )
                try:
                    with self.assertRaises(KindleError) as failed:
                        client.register(
                            LoginAttempt("synthetic"),
                            {"authorization_code": "PRIVATE_CODE"},
                        )
                    self.assertEqual(
                        failed.exception.diagnostic()["authentication"]["reason"],
                        "unknown",
                    )
                    self.assertNotIn(
                        "PRIVATE",
                        str(failed.exception)
                        + json.dumps(failed.exception.diagnostic()),
                    )
                finally:
                    client.close()

    def test_diagnostic_does_not_accept_arbitrary_authentication_strings(self):
        error = KindleError(
            "test",
            "Test",
            authentication={
                "reason": "PRIVATE_CODE",
                "flow": "PRIVATE",
                "url": "https://amazon.it/?code=PRIVATE",
            },
        )
        self.assertNotIn("PRIVATE", json.dumps(error.diagnostic()))

    def test_application_redeems_inside_browser_lifetime(self):
        with tempfile.TemporaryDirectory() as temporary:
            client = MagicMock()
            client.session = None
            events = []
            client.register.side_effect = lambda attempt, data: events.append(
                "register"
            )

            def browser(attempt, *, channel, on_auth):
                events.append("browser_open")
                on_auth({"authorization_code": "synthetic"})
                events.append("browser_close")

            with (
                patch(
                    "tool.kindle_personal.browser.capture_login", side_effect=browser
                ),
                redirect_stdout(io.StringIO()),
            ):
                Application(Path(temporary), client=client).login()
            self.assertEqual(events, ["browser_open", "register", "browser_close"])
            client.register.assert_called_once()

    def test_browser_failure_closes_browser_without_losing_registration_diagnostics(
        self,
    ):
        browser = MagicMock()
        playwright = MagicMock()
        playwright.chromium.launch.return_value = browser
        error = KindleError("amazon_http", "Failed", stage="register", status=400)
        with (
            patch("playwright.sync_api.sync_playwright") as sync,
            patch("tool.kindle_personal.browser.capture_in_context", side_effect=error),
        ):
            sync.return_value.__enter__.return_value = playwright
            with self.assertRaises(KindleError) as failed:
                capture_login(LoginAttempt("synthetic"), on_auth=lambda data: None)
        self.assertIs(failed.exception, error)
        browser.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
