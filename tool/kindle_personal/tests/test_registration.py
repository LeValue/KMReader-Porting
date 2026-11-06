import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import MagicMock, patch

import httpx

from tool.kindle_personal.auth import LoginAttempt, registration_error_reason
from tool.kindle_personal.browser import capture_login
from tool.kindle_personal.cli import Application
from tool.kindle_personal.client import KindleClient
from tool.kindle_personal.common import KindleError
from tool.kindle_personal.selfcheck import MemoryVault


class RegistrationErrorTest(unittest.TestCase):
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
