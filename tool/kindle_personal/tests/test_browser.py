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
