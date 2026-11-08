"""Private Windows IPC for the opt-in STK probe; never print session values."""

import argparse
import json
import sys
from pathlib import Path

from tool.kindle_personal.storage import WindowsVault, default_directory


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
        path.write_text(json.dumps({"session": session}), encoding="utf-8")
    else:
        session = json.loads(path.read_text(encoding="utf-8"))["session"]
        if session.get("customer_id") != existing["customer_id"]:
            raise ValueError("account_mismatch")
        device = session.get("send_device", {})
        if device.get("adp_token") and device.get("device_private_key"):
            cache.save({"customer_id": existing["customer_id"], "send_device": device})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("export", "seal"))
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    try:
        transfer(args.operation, args.path)
    except Exception:
        # DPAPI, file paths and session records must not enter Actions logs.
        print("Kindle probe private session unavailable.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
