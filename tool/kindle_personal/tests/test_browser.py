import os
import unittest
from urllib.parse import urlencode

from tool.kindle_personal.auth import LoginAttempt
from tool.kindle_personal.browser import capture_in_context
from tool.kindle_personal.common import KindleError


@unittest.skipUnless(
    os.environ.get("KMREADER_KINDLE_BROWSER_TEST") == "1",
    "Opt-in real browser boundary test",
)
class BrowserBoundaryTest(unittest.TestCase):
    def test_otp_callback_with_raw_slashes_is_intercepted_before_upstream_redemption(
        self,
    ):
        from playwright.sync_api import sync_playwright

        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            try:
                context = browser.new_context(service_workers="block")
                attempt = LoginAttempt("synthetic-otp")
                credential = "synthetic/code+percent%2F"
                callback = "https://www.amazon.it/ap/maplanding?" + urlencode(
                    {
                        "openid.ns": "http://specs.openid.net/auth/2.0",
                        "openid.identity": "https://www.amazon.it/ap/user/synthetic",
                        "openid.oa2.authorization_code": credential,
                        "openid.oa2.state": attempt.state,
                    },
                    safe="/",
                )
                forwarded, challenge, redeemed = [], [], []

                def upstream(route):
                    url = route.request.url
                    if "/ap/signin?" in url:
                        route.fulfill(
                            content_type="text/html",
                            body='<script>location.href="https://www.amazon.it/ap/challenge-otp";</script>',
                        )
                    elif "/ap/challenge-otp" in url:
                        challenge.append(True)
                        route.fulfill(
                            content_type="text/html",
                            body=f"<script>location.href={callback!r};</script>",
                        )
                    else:
                        forwarded.append(url)
                        route.fulfill(
                            content_type="text/html",
                            body="<p>Upstream would consume the one-use code.</p>",
                        )

                context.route("**/*", upstream)

                def redeem(data):
                    self.assertFalse(
                        forwarded, "A callback must never reach Amazon landing first"
                    )
                    self.assertEqual(data["authorization_code"], credential)
                    self.assertEqual(data["code_verifier"], attempt.verifier)
                    self.assertFalse(context.pages[0].is_closed())
                    self.assertIn(
                        "authorization_code",
                        context.pages[0].url,
                        "Redemption must precede cleanup RPCs",
                    )
                    redeemed.append(data)

                result = capture_in_context(context, attempt, timeout=5, on_auth=redeem)
                self.assertTrue(challenge)
                self.assertFalse(forwarded)
                self.assertEqual(redeemed, [result])
                self.assertEqual(
                    context.pages[0].url, "https://www.amazon.it/ap/maplanding"
                )
                context.close()
            finally:
                browser.close()

    def test_fragment_token_does_not_visit_a_nonexistent_amazon_landing_page(self):
        from playwright.sync_api import sync_playwright

        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            try:
                context = browser.new_context()
                attempt = LoginAttempt("synthetic-fragment", "token")
                callback = "https://www.amazon.it/ap/maplanding#" + urlencode(
                    {
                        "openid.oa2.access_token": "synthetic/token",
                        "openid.oa2.state": attempt.state,
                    }
                )
                forwarded = []

                def upstream(route):
                    if "/ap/signin?" in route.request.url:
                        route.fulfill(
                            content_type="text/html",
                            body=f"<script>location.href={callback!r};</script>",
                        )
                    else:
                        forwarded.append(True)
                        route.fulfill(status=404, body="Page does not exist")

                context.route("**/*", upstream)
                result = capture_in_context(context, attempt, timeout=5)
                self.assertEqual(result["access_token"], "synthetic/token")
                self.assertFalse(forwarded)
                context.close()
            finally:
                browser.close()

    def test_subframe_cannot_supply_the_main_frame_authorization_code(self):
        from playwright.sync_api import sync_playwright

        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            try:
                context = browser.new_context()
                attempt = LoginAttempt("synthetic-subframe")
                base = (
                    "https://www.amazon.it/ap/maplanding?openid.oa2.state="
                    + attempt.state
                    + "&openid.oa2.authorization_code="
                )
                context.route(
                    "**/*",
                    lambda route: route.fulfill(
                        content_type="text/html",
                        body=(
                            f'<iframe src="{base}subframe-code"></iframe>'
                            f"<script>setTimeout(()=>location.href={(base + 'main-frame-code')!r},300);</script>"
                        ),
                    ),
                )
                self.assertEqual(
                    capture_in_context(context, attempt, timeout=5)[
                        "authorization_code"
                    ],
                    "main-frame-code",
                )
                context.close()
            finally:
                browser.close()

    def test_missing_callback_result_returns_a_specific_error(self):
        from playwright.sync_api import sync_playwright

        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            try:
                context = browser.new_context()
                context.route(
                    "**/*",
                    lambda route: route.fulfill(
                        content_type="text/html",
                        body='<script>location.href="https://www.amazon.it/ap/maplanding";</script>',
                    ),
                )
                with self.assertRaises(KindleError) as failure:
                    capture_in_context(
                        context, LoginAttempt("synthetic-missing"), timeout=5
                    )
                self.assertEqual(failure.exception.code, "login_callback_missing")
                context.close()
            finally:
                browser.close()

    def test_query_and_fragment_callbacks_in_an_ephemeral_real_browser(self):
        from playwright.sync_api import sync_playwright

        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            try:
                for flow, field in (
                    ("pkce", "authorization_code"),
                    ("token", "access_token"),
                ):
                    for separator in ("?", "#"):
                        with self.subTest(flow=flow, separator=separator):
                            context = browser.new_context(service_workers="block")
                            try:
                                attempt = LoginAttempt("synthetic-browser", flow)
                                callback = (
                                    "https://www.amazon.it/ap/maplanding"
                                    + separator
                                    + urlencode(
                                        {
                                            "openid.oa2."
                                            + field: "synthetic-browser-secret",
                                            "openid.oa2.state": attempt.state,
                                        }
                                    )
                                )

                                def upstream(route):
                                    if "/ap/signin?" in route.request.url:
                                        route.fulfill(
                                            content_type="text/html",
                                            body=f"<script>location.href={callback!r};</script>",
                                        )
                                    else:
                                        route.fulfill(
                                            content_type="text/html",
                                            body="<p>Synthetic landing</p>",
                                        )

                                context.route("**/*", upstream)
                                result = capture_in_context(context, attempt, timeout=5)
                                self.assertEqual(
                                    result[field], "synthetic-browser-secret"
                                )
                                self.assertEqual(context.cookies(), [])
                            finally:
                                context.close()
            finally:
                browser.close()

    def test_wrong_state_is_rejected_without_navigating_upstream(self):
        from playwright.sync_api import sync_playwright

        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            try:
                context = browser.new_context()
                context.route(
                    "**/*",
                    lambda route: route.fulfill(
                        content_type="text/html",
                        body=(
                            '<script>location.href="https://www.amazon.it/ap/maplanding?openid.oa2.authorization_code=secret&openid.oa2.state=wrong";</script>'
                        ),
                    ),
                )
                with self.assertRaises(KindleError) as failure:
                    capture_in_context(context, LoginAttempt("synthetic"), timeout=5)
                self.assertEqual(failure.exception.code, "login_state")
                context.close()
            finally:
                browser.close()


if __name__ == "__main__":
    unittest.main()
