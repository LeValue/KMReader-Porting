"""Visible browser, manual Amazon login/MFA. No form automation, trace or HAR."""

import os
import time

from .common import KindleError


def capture_login(attempt, *, channel=None, timeout=600, on_auth=None):
    from playwright.sync_api import Error, sync_playwright

    with sync_playwright() as playwright:
        selected = channel or ("chrome" if os.name == "nt" else None)
        try:
            browser = playwright.chromium.launch(
                headless=False,
                channel=selected,
            )
        except Error:
            raise KindleError(
                "browser_missing",
                (
                    "Google Chrome"
                    if selected == "chrome"
                    else "Microsoft Edge"
                    if selected == "msedge"
                    else "Chromium"
                )
                + " non disponibile. Installa il browser scelto oppure cambialo dal menu 10.",
                stage="login",
            ) from None
        try:
            context = browser.new_context(service_workers="block")
            return capture_in_context(
                context, attempt, timeout=timeout, on_auth=on_auth
            )
        except Error:
            raise KindleError(
                "browser_closed",
                "Finestra di accesso chiusa prima del completamento.",
                stage="login",
            ) from None
        finally:
            try:
                browser.close()
            except Error:
                pass


def capture_in_context(context, attempt, *, timeout=600, on_auth=None):
    """The real browser boundary; tests intercept all upstream pages locally."""
    from playwright.sync_api import Error

    result, errors = [], []

    def accept(url):
        try:
            auth_data = attempt.callback(url)
            if auth_data is not None and not result:
                result.append(auth_data)
            return auth_data is not None
        except KindleError as error:
            errors.append(error)
            return True

    page = context.new_page()

    def landing(route):
        if (
            not route.request.is_navigation_request()
            or route.request.frame != page.main_frame
        ):
            route.abort()
            return
        accept(route.request.url)
        # Fragments are not part of the HTTP request URL. Even when the request
        # has no code, fulfill locally and read the fragment on navigation. Never
        # let Amazon's landing page consume or replace the one-use result first.
        route.fulfill(
            status=200,
            content_type="text/html",
            body=(
                '<meta name="referrer" content="no-referrer">'
                "<h2>Verifica del collegamento in corso. Torna a KMReader Kindle.</h2>"
            ),
        )

    # Playwright's trailing '*' does not match '/' inside a query either.
    # Amazon callback parameters can contain slash-bearing OpenID URLs and
    # opaque codes. Match the parsed origin/path independently of the query.
    context.route(attempt.is_callback_url, landing)

    def navigated(frame):
        if frame != page.main_frame or not attempt.is_callback_url(frame.url):
            return
        accepted = accept(frame.url)
        if not accepted and not errors and not result:
            errors.append(
                KindleError(
                    "login_callback_missing",
                    "Amazon non ha restituito il risultato di accesso previsto. Riprova dal menu 1.",
                    stage="login",
                )
            )

    page.on("framenavigated", navigated)
    try:
        response = page.goto(
            attempt.url(), wait_until="domcontentloaded", timeout=60_000
        )
        if response and response.status >= 400 and not result and not errors:
            raise KindleError(
                "login_page_http",
                "Amazon non ha aperto la pagina di accesso per questo profilo.",
                stage="login",
                status=response.status,
            )
    except Error:
        if not result and not errors:
            raise KindleError(
                "login_navigation",
                "Impossibile caricare l'accesso Amazon. Controlla la connessione e riprova.",
                stage="login",
            ) from None
    deadline = time.monotonic() + timeout
    while (
        not result
        and not errors
        and not page.is_closed()
        and time.monotonic() < deadline
    ):
        page.wait_for_timeout(100)
    if errors:
        raise errors[0]
    if not result:
        raise KindleError(
            "login_incomplete",
            "Login interrotto o scaduto. Nessuna password o codice salvato.",
            stage="login",
        )
    # Redeem before even the cleanup RPCs and Edge shutdown. On a slower laptop
    # those must not consume the lifetime of a one-use authorization code.
    if on_auth is not None:
        on_auth(result[0])
    # Own neutral page: remove query/fragment only after the result has been
    # captured, including fragment-only token flows. No secret enters script.
    try:
        page.evaluate("history.replaceState(null, '', '/ap/maplanding')")
    except Error:
        pass
    return result[0]
