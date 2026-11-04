"""Visible browser, manual Amazon login/MFA. No form automation, trace or HAR."""

import os
import time

from .common import KindleError


def capture_login(attempt, *, channel=None, timeout=600):
    from playwright.sync_api import Error, sync_playwright

    with sync_playwright() as playwright:
        try:
            browser = playwright.chromium.launch(
                headless=False,
                channel=channel or ("msedge" if os.name == "nt" else None),
            )
        except Error:
            raise KindleError(
                "browser_missing",
                "Microsoft Edge non disponibile. Installa Edge oppure usa --browser chrome.",
                stage="login",
            ) from None
        try:
            context = browser.new_context(service_workers="block")
            return capture_in_context(context, attempt, timeout=timeout)
        except Error:
            raise KindleError(
                "browser_closed",
                "Finestra di accesso chiusa prima del completamento.",
                stage="login",
            ) from None
        finally:
            browser.close()


def capture_in_context(context, attempt, *, timeout=600):
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

    def landing(route):
        if accept(route.request.url):
            route.fulfill(
                status=200,
                content_type="text/html",
                body=(
                    '<meta name="referrer" content="no-referrer">'
                    "<h2>Accesso ricevuto. Puoi tornare a KMReader Kindle.</h2>"
                    '<script>history.replaceState(null,"","/ap/maplanding");</script>'
                ),
            )
        else:
            route.fallback()

    context.route("**/ap/maplanding*", landing)
    page = context.new_page()
    page.on(
        "framenavigated",
        lambda frame: accept(frame.url) if frame == page.main_frame else None,
    )
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
    return result[0]
