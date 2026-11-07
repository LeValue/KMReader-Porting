"""Windows DPAPI, scoped to the logged-in user. No plaintext secret fallback."""

import ctypes
import json
import os
from ctypes import wintypes
from pathlib import Path

from .common import KindleError, atomic_bytes, digest


def default_directory() -> Path:
    if os.name != "nt":
        raise KindleError(
            "windows_required", "Questo prototipo personale richiede Windows."
        )
    return Path(os.environ["LOCALAPPDATA"]) / "KMReader" / "KindlePrototype"


class _Blob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_ubyte))]


def _dpapi(data: bytes, *, decrypt: bool) -> bytes:
    if os.name != "nt":
        raise KindleError(
            "vault_unavailable", "Archivio protetto Windows non disponibile."
        )
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    buffer = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
    source, target = _Blob(len(data), buffer), _Blob()
    # CRYPTPROTECT_UI_FORBIDDEN; intentionally omit CRYPTPROTECT_LOCAL_MACHINE.
    if decrypt:
        fn = crypt.CryptUnprotectData
        fn.argtypes = [
            ctypes.POINTER(_Blob),
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
            wintypes.DWORD,
            ctypes.POINTER(_Blob),
        ]
        ok = fn(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target))
    else:
        fn = crypt.CryptProtectData
        fn.argtypes = [
            ctypes.POINTER(_Blob),
            wintypes.LPCWSTR,
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
            wintypes.DWORD,
            ctypes.POINTER(_Blob),
        ]
        ok = fn(
            ctypes.byref(source),
            "KMReader Kindle",
            None,
            None,
            None,
            1,
            ctypes.byref(target),
        )
    fn.restype = wintypes.BOOL
    if not ok:
        raise KindleError(
            "vault_failed", "Impossibile accedere alle credenziali protette Windows."
        )
    try:
        return ctypes.string_at(target.pbData, target.cbData)
    finally:
        kernel.LocalFree(target.pbData)


class WindowsVault:
    def __init__(self, directory: Path):
        self.path = directory / "session.dpapi"

    def load(self):
        if not self.path.exists():
            return None
        try:
            return json.loads(_dpapi(self.path.read_bytes(), decrypt=True))
        except (ValueError, OSError):
            raise KindleError(
                "vault_record",
                "Sessione protetta non leggibile su questo utente Windows.",
            ) from None

    def save(self, session):
        atomic_bytes(self.path, _dpapi(json.dumps(session).encode(), decrypt=False))

    def clear(self):
        self.path.unlink(missing_ok=True)


def account_key(session) -> str:
    identity = session.get("customer_id")
    if not identity:
        raise KindleError(
            "account_identity", "Identità account assente dalla registrazione."
        )
    return digest("amazon.it\0" + identity)[:32]
