"""Amazon.it device identity protocol experiment, not Login with Amazon profile OAuth.

Implemented independently from observed request fields documented in the research
report. The Kindle client profile is historical; server acceptance needs a real
account test. PKCE support for this profile is experimental, never silently
downgraded. Credentials only exist in memory until sealed by Windows DPAPI.
"""

import base64
import hashlib
import secrets
import uuid
from dataclasses import dataclass, field
from urllib.parse import parse_qs, urlencode, urlsplit

from .common import KindleError

DEVICE_TYPE = "AGZZ1ST63LKBW"
APP_VERSION = "6.38.0.100"
SOFTWARE_VERSION = "1184366692"
USER_AGENT = "Kindle/1.0.235280.0.10 CFNetwork/1220.1 Darwin/20.3.0"
PROFILE = "kindle-ios-6.38-experimental"


@dataclass(repr=False)
class LoginAttempt:
    serial: str
    flow: str = "pkce"
    verifier: str = field(default_factory=lambda: secrets.token_urlsafe(48))
    state: str = field(default_factory=lambda: secrets.token_urlsafe(32))

    def __post_init__(self):
        if self.flow not in ("pkce", "token"):
            raise ValueError("Unknown login flow")

    @property
    def client_id(self):
        return (self.serial + "#" + DEVICE_TYPE).encode().hex()

    def url(self):
        params = {
            "openid.return_to": "https://www.amazon.it/ap/maplanding",
            "openid.assoc_handle": "amzn_kindle_for_ios_it",
            "openid.identity": "http://specs.openid.net/auth/2.0/identifier_select",
            "openid.claimed_id": "http://specs.openid.net/auth/2.0/identifier_select",
            "openid.mode": "checkid_setup",
            "openid.ns": "http://specs.openid.net/auth/2.0",
            "openid.ns.oa2": "http://www.amazon.com/ap/ext/oauth/2",
            "openid.ns.pape": "http://specs.openid.net/extensions/pape/1.0",
            "openid.pape.max_auth_age": "0",
            "openid.oa2.client_id": "device:" + self.client_id,
            "openid.oa2.scope": "device_auth_access",
            "openid.oa2.response_type": "code" if self.flow == "pkce" else "token",
            "openid.oa2.state": self.state,
            "pageId": "amzn_kindle_for_ios_branded",
            "accountStatusPolicy": "P1",
        }
        if self.flow == "pkce":
            challenge = hashlib.sha256(self.verifier.encode()).digest()
            params.update(
                {
                    "openid.oa2.code_challenge_method": "S256",
                    "openid.oa2.code_challenge": base64.urlsafe_b64encode(challenge)
                    .decode()
                    .rstrip("="),
                }
            )
        return "https://www.amazon.it/ap/signin?" + urlencode(params)

    def callback(self, url: str):
        """Only called for navigation in our ephemeral browser context."""
        parsed = urlsplit(url)
        if (parsed.scheme, parsed.netloc, parsed.path) != (
            "https",
            "www.amazon.it",
            "/ap/maplanding",
        ):
            return None
        values = parse_qs(parsed.query + "&" + parsed.fragment)
        if "error" in values or "openid.oa2.error" in values:
            raise KindleError(
                "login_rejected",
                "Amazon ha rifiutato questo flusso di accesso.",
                stage="login",
            )
        state = values.get("openid.oa2.state", values.get("state"))
        if state is not None and state != [self.state]:
            raise KindleError(
                "login_state",
                "Il risultato del login non appartiene a questa sessione.",
                stage="login",
            )
        # Some historical Amazon device flows do not echo state. PKCE binds the
        # code to this attempt; the legacy token flow is captured only in-context.
        name = "authorization_code" if self.flow == "pkce" else "access_token"
        token = values.get("openid.oa2." + name)
        if token is None:
            return None
        if len(token) != 1 or not token[0]:
            raise KindleError(
                "login_callback", "Risultato login non valido.", stage="login"
            )
        if self.flow == "pkce":
            return {
                "client_id": self.client_id,
                "authorization_code": token[0],
                "code_verifier": self.verifier,
                "code_algorithm": "SHA-256",
                "client_domain": "DeviceLegacy",
            }
        return {"access_token": token[0]}


def new_serial() -> str:
    return uuid.uuid4().hex.upper()


def registration_body(attempt: LoginAttempt, auth_data):
    return {
        "requested_token_type": ["bearer", "mac_dms"],
        "registration_data": {
            "domain": "Device",
            "app_name": "Kindle for iOS",
            "app_version": APP_VERSION,
            "device_type": DEVICE_TYPE,
            "device_serial": attempt.serial,
            "device_name": "KMReader personale",
            "device_model": "iPhone",
            "os_version": "14.4",
            "software_version": SOFTWARE_VERSION,
        },
        "auth_data": auth_data,
        "requested_extensions": ["device_info", "customer_info"],
    }
