"""Bounded device HTTP operations. No deregistration or library mutations."""

import base64
import json
import time
from datetime import datetime, timezone
from urllib.parse import quote, urlsplit

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

from .auth import (
    APP_VERSION,
    DEVICE_TYPE,
    SOFTWARE_VERSION,
    USER_AGENT,
    registration_body,
    registration_error_reason,
)
from .common import KindleError

CATALOG_URL = "https://todo-ta-g7g.amazon.com/FionaTodoListProxy/syncMetaData"
DELIVERY_URL = "https://kindle-digital-delivery.amazon.com/delivery/manifest/"
SIGNING_HOSTS = {
    "todo-ta-g7g.amazon.com",
    "kindle-digital-delivery.amazon.com",
    "cde-ta-g7g.amazon.com",
}
DOWNLOAD_SUFFIXES = (
    "amazon.com",
    "amazon.it",
    "amazonaws.com",
    "cloudfront.net",
    "media-amazon.com",
    "images-amazon.com",
    "ssl-images-amazon.com",
)


def check_url(url: str):
    try:
        p = urlsplit(url)
        host = p.hostname or ""
        valid = (
            p.scheme == "https"
            and p.port in (None, 443)
            and not p.username
            and not p.password
            and not p.fragment
            and any(
                host == suffix or host.endswith("." + suffix)
                for suffix in DOWNLOAD_SUFFIXES
            )
        )
    except ValueError:
        valid = False
    if not valid:
        raise KindleError(
            "delivery_address",
            "Indirizzo di consegna non supportato; nessuna credenziale inviata.",
            stage="download",
        )


def signing_headers(request: httpx.Request, session, *, timestamp=None):
    timestamp = timestamp or datetime.now(timezone.utc).isoformat(
        timespec="seconds"
    ).replace("+00:00", "Z")
    path = request.url.raw_path.decode("ascii")  # Includes the exact encoded query.
    message = (request.method + "\n" + path + "\n" + timestamp + "\n").encode()
    message += request.content + b"\n" + session["adp_token"].encode()
    key_data = session["device_private_key"].encode()
    try:
        if key_data.startswith(b"-----BEGIN"):
            key = serialization.load_pem_private_key(key_data, password=None)
        else:
            key = serialization.load_der_private_key(
                base64.b64decode(key_data), password=None
            )
        signature = key.sign(message, padding.PKCS1v15(), hashes.SHA256())
    except (ValueError, TypeError):
        raise KindleError(
            "device_key", "Chiave del dispositivo non valida.", stage="authentication"
        ) from None
    return {
        "x-adp-token": session["adp_token"],
        "x-adp-alg": "SHA256withRSA:1.0",
        "x-adp-signature": base64.b64encode(signature).decode() + ":" + timestamp,
    }


class KindleClient:
    def __init__(self, vault, *, transport=None):
        self.vault = vault
        self.http = httpx.Client(
            transport=transport,
            timeout=httpx.Timeout(60, connect=20),
            follow_redirects=False,
            headers={"Accept-Encoding": "identity"},
        )
        self.session = vault.load()

    def close(self):
        self.http.close()

    @staticmethod
    def _check(response, stage):
        if not 200 <= response.status_code < 300:
            status = response.status_code
            hint = (
                "Accesso al contenuto non autorizzato per questa sessione."
                if status in (401, 403)
                else "Il servizio Amazon non ha completato la richiesta."
            )
            raise KindleError("amazon_http", hint, stage=stage, status=status)

    def _json(self, method, url, *, stage, **kwargs):
        try:
            self.http.cookies.clear()
            with self.http.stream(method, url, **kwargs) as response:
                chunks, size = [], 0
                for chunk in response.iter_bytes():
                    size += len(chunk)
                    if size > 16 * 1024 * 1024:
                        raise KindleError(
                            "response_size",
                            "Risposta Amazon troppo grande.",
                            stage=stage,
                            status=response.status_code,
                        )
                    chunks.append(chunk)
                raw = b"".join(chunks)
                try:
                    value = json.loads(raw)
                    response_format = "json"
                except (ValueError, UnicodeError):
                    value = None
                    response_format = "other" if raw else "empty"
                if not 200 <= response.status_code < 300:
                    try:
                        self._check(response, stage)
                    except KindleError as error:
                        if stage in {"register", "refresh"}:
                            reason = registration_error_reason(value)
                            error.add_authentication(
                                {"reason": reason, "response_format": response_format}
                            )
                        raise
                if not isinstance(value, dict):
                    raise ValueError()
                return value
        except (ValueError, UnicodeError):
            raise KindleError(
                "amazon_response",
                "Formato della risposta Amazon non riconosciuto.",
                stage=stage,
            ) from None
        except httpx.HTTPError:
            raise KindleError(
                "network", "Connessione Amazon non riuscita. Riprova.", stage=stage
            ) from None

    def register(self, attempt, auth_data):
        if self.session:
            raise KindleError(
                "already_connected",
                "Account già collegato: usa la sessione esistente o scollega prima il prototipo.",
            )
        try:
            data = self._json(
                "POST",
                "https://api.amazon.it/auth/register",
                stage="register",
                json=registration_body(attempt, auth_data),
                headers={"User-Agent": USER_AGENT, "Accept-Language": "it-IT"},
            )
        except KindleError as error:
            error.add_authentication({"flow": attempt.flow, "entry": attempt.entry})
            raise
        try:
            success = data["response"]["success"]
            tokens, extensions = success["tokens"], success["extensions"]
            bearer, adp = tokens["bearer"], tokens["mac_dms"]
            customer = extensions["customer_info"]
            customer_id = customer.get("user_id") or customer.get("customer_id")
            session = {
                "marketplace": "amazon.it",
                "profile": attempt.profile,
                "serial": attempt.serial,
                "device_type": DEVICE_TYPE,
                "customer_id": customer_id,
                "flow": attempt.flow,
                "access_token": bearer["access_token"],
                "refresh_token": bearer["refresh_token"],
                "expires": time.time() + int(bearer["expires_in"]),
                "adp_token": adp["adp_token"],
                "device_private_key": adp["device_private_key"],
            }
            if not all(
                isinstance(session[k], str) and session[k]
                for k in (
                    "customer_id",
                    "access_token",
                    "refresh_token",
                    "adp_token",
                    "device_private_key",
                )
            ):
                raise ValueError()
        except (ValueError, KeyError, TypeError):
            raise KindleError(
                "registration_shape",
                "Registrazione non compatibile con il connettore. Nessuna sessione dichiarata valida.",
                stage="register",
            ) from None
        # Persist before requesting the catalog: a catalog failure must not cause
        # the next attempt to register a new logical device.
        self.vault.save(session)
        self.session = session

    def require_session(self):
        if not self.session or self.session.get("marketplace") != "amazon.it":
            raise KindleError(
                "not_connected",
                "Collega prima l'account Amazon.it.",
                stage="authentication",
            )

    def refresh(self):
        self.require_session()
        if self.session["expires"] > time.time() + 60:
            return
        data = self._json(
            "POST",
            "https://api.amazon.it/auth/token",
            stage="refresh",
            data={
                "app_name": "Kindle for iOS",
                "app_version": APP_VERSION,
                "source_token_type": "refresh_token",
                "source_token": self.session["refresh_token"],
                "requested_token_type": "access_token",
            },
        )
        try:
            updated = {
                **self.session,
                "access_token": data["access_token"],
                "expires": time.time() + int(data["expires_in"]),
            }
            if (
                not isinstance(updated["access_token"], str)
                or not updated["access_token"]
            ):
                raise ValueError()
        except (KeyError, ValueError, TypeError):
            raise KindleError(
                "refresh_shape",
                "Rinnovo della sessione non riconosciuto.",
                stage="refresh",
            ) from None
        self.vault.save(updated)
        self.session = updated

    def request(self, url, *, stage, headers=None, params=None):
        self.refresh()
        check_url(url)
        self.http.cookies.clear()
        public_headers = {
            "User-Agent": USER_AGENT,
            **{
                key: value
                for key, value in (headers or {}).items()
                if key.lower() in {"range", "if-range"}
            },
        }
        request = self.http.build_request(
            "GET", url, params=params, headers=public_headers
        )
        if request.url.host in SIGNING_HOSTS:
            request.headers.update(headers or {})
            request.headers.update(signing_headers(request, self.session))
        try:
            response = self.http.send(request, stream=True)
        except httpx.HTTPError:
            raise KindleError(
                "network", "Connessione Amazon non riuscita. Riprova.", stage=stage
            ) from None
        # Never copy signatures/cookies to the redirect target. Rebuild and sign
        # only an independently allowlisted Amazon device-service request.
        for _ in range(5):
            if not response.is_redirect:
                try:
                    self._check(response, stage)
                except KindleError:
                    response.close()
                    raise
                return response
            next_url = str(response.url.join(response.headers.get("location", "")))
            response.close()
            check_url(next_url)
            self.http.cookies.clear()
            request = self.http.build_request("GET", next_url, headers=public_headers)
            if request.url.host in SIGNING_HOSTS:
                request.headers.update(headers or {})
                request.headers.update(signing_headers(request, self.session))
            try:
                response = self.http.send(request, stream=True)
            except httpx.HTTPError:
                raise KindleError(
                    "network",
                    "Connessione interrotta durante la consegna.",
                    stage=stage,
                ) from None
        response.close()
        raise KindleError(
            "redirects", "Troppi reindirizzamenti nella consegna Amazon.", stage=stage
        )

    def bounded_get(self, url, *, stage, limit=16 * 1024 * 1024, **kwargs):
        response = self.request(url, stage=stage, **kwargs)
        try:
            chunks, size = [], 0
            for chunk in response.iter_bytes():
                size += len(chunk)
                if size > limit:
                    raise KindleError(
                        "response_size", "Risposta Amazon troppo grande.", stage=stage
                    )
                chunks.append(chunk)
            return b"".join(chunks)
        except httpx.HTTPError:
            raise KindleError(
                "network", "Trasferimento interrotto. Riprova.", stage=stage
            ) from None
        finally:
            response.close()

    def manifest(self, item):
        self.require_session()
        category = "pdoc" if item["type"] == "PDOC" else "ebook"
        correlation = (
            f"Device:{self.session['device_type']}:{self.session['serial']};"
            f"kindle.{item['type']}:{item['id']}:{int(time.time() * 1000)}"
        )
        headers = {
            "X-ADP-AttemptCount": "1",
            "X-ADP-CorrelationId": correlation,
            "X-ADP-Transport": "WiFi",
            "X-ADP-Reason": "ArchivedItems",
            "Accept-Language": "it-IT",
            "X-ADP-SW": SOFTWARE_VERSION,
            "x-amzn-accept-type": "application/x.amzn.digital.deliverymanifest@1.0",
        }
        raw = self.bounded_get(
            DELIVERY_URL + "kindle." + category + "/" + quote(item["id"], safe=""),
            stage="manifest",
            headers=headers,
        )
        try:
            manifest = json.loads(raw)
            if (
                not isinstance(manifest, dict)
                or not isinstance(manifest.get("resources"), list)
                or not manifest["resources"]
            ):
                raise ValueError()
            content = manifest.get("content", {})
            if content.get("id", item["id"]) != item["id"]:
                raise ValueError()
            return manifest, headers
        except (ValueError, AttributeError):
            raise KindleError(
                "manifest_shape",
                "Manifest assente o non compatibile; nessun dispositivo viene scollegato.",
                stage="manifest",
            ) from None
