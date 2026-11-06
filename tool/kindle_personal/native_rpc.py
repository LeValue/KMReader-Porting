"""Private native worker: local preparation and scoped cover URLs, no sessions."""

import io
import json
import sys
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


def execute(request):
    operation = request.get("operation")
    if operation == "prepare":
        from .prepare import prepare_download

        result = prepare_download(
            Path(request["directory"]).resolve(), convert=True, inline=True
        )
        return {"ok": result["state"] == "importable", "preparation": result}
    if operation == "cover":
        from .cover import remote_cover

        return {"ok": True, "cover": remote_cover(request.get("urls", []))}
    raise ValueError("Worker operation")


def main():
    for line in sys.stdin:
        identifier = None
        try:
            if len(line) > 64 * 1024:
                raise ValueError("Worker request")
            request = json.loads(line)
            identifier = request.get("id")
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                response = execute(request)
        except Exception:
            response = {"ok": False, "error": {"code": "preparation_failed"}}
        print(
            json.dumps({"id": identifier, **response}, separators=(",", ":")),
            flush=True,
        )
    return 0
