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
        payload = {"session": session}
        if cached and cached.get("customer_id") == existing["customer_id"] and cached.get("probe_operation"):
            payload["probe_operation"] = cached["probe_operation"]
        if cached and cached.get("customer_id") == existing["customer_id"] and cached.get("management_probe"):
            payload["management_probe"] = cached["management_probe"]
        if cached and cached.get("customer_id") == existing["customer_id"] and cached.get("delivery_probes"):
            payload["delivery_probes"] = cached["delivery_probes"]
        path.write_text(json.dumps(payload), encoding="utf-8")
    elif operation == "attach-fixture":
        payload = json.loads(path.read_text(encoding="utf-8"))
        cached = cache.load() or {}
        if (payload.get("session", {}).get("customer_id") != existing["customer_id"]
                or cached.get("customer_id") != existing["customer_id"]
                or not cached.get("probe_operation", {}).get("catalog_id")):
            raise ValueError("probe_fixture_missing")
        payload["probe_operation"] = cached["probe_operation"]
        path.write_text(json.dumps(payload), encoding="utf-8")
    else:
        payload = json.loads(path.read_text(encoding="utf-8"))
        session = payload["session"]
        if session.get("customer_id") != existing["customer_id"]:
            raise ValueError("account_mismatch")
        record = cache.load() or {}
        if record.get("customer_id") != existing["customer_id"]:
            record = {"customer_id": existing["customer_id"]}
        device = session.get("send_device", {})
        if device.get("adp_token") and device.get("device_private_key"):
            record["send_device"] = device
        if payload.get("probe_operation"):
            record["probe_operation"] = payload["probe_operation"]
        if payload.get("management_probe"):
            record["management_probe"] = payload["management_probe"]
        if payload.get("delivery_probes"):
            record["delivery_probes"] = payload["delivery_probes"]
        if record.get("send_device") or record.get("probe_operation") or record.get("management_probe") or record.get("delivery_probes"):
            cache.save(record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("export", "seal", "attach-fixture"))
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
