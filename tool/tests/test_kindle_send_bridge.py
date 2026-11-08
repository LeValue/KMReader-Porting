import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tool import kindle_send_probe_bridge as bridge


class SendBridgeTest(unittest.TestCase):
    def test_account_scope_and_dpapi_cache_contains_only_send_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "KindlePrototype"
            target = root / "KindleSendProbe"
            records = {source: {"customer_id": "synthetic-account", "refresh_token": "PRIVATE"}}

            class Vault:
                def __init__(self, path):
                    self.path = path

                def load(self):
                    return records.get(self.path)

                def save(self, value):
                    records[self.path] = value

            with patch.object(bridge, "WindowsVault", Vault), patch.object(
                bridge, "default_directory", lambda: source
            ):
                ipc = root / "private.json"
                device = {"adp_token": "SYNTHETIC", "device_private_key": "SYNTHETIC"}
                # Never import a different account's STK credentials.
                records[target] = {"customer_id": "other-account", "send_device": device}
                bridge.transfer("export", ipc)
                session = json.loads(ipc.read_text())["session"]
                self.assertNotIn("send_device", session)
                session["send_device"] = device
                ipc.write_text(json.dumps({"session": session}))
                bridge.transfer("seal", ipc)
                self.assertEqual(records[target], {"customer_id": "synthetic-account", "send_device": device})
                self.assertEqual(records[source], {"customer_id": "synthetic-account", "refresh_token": "PRIVATE"})
                bridge.transfer("export", ipc)
                self.assertEqual(json.loads(ipc.read_text())["session"]["send_device"], device)
                session["customer_id"] = "other-account"
                ipc.write_text(json.dumps({"session": session}))
                with self.assertRaisesRegex(ValueError, "account_mismatch"):
                    bridge.transfer("seal", ipc)


if __name__ == "__main__":
    unittest.main()
