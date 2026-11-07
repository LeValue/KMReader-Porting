"""Validated random access for prototype probes; bounded cache, no URL logging."""

import re
import tempfile
from collections import OrderedDict
from pathlib import Path

from .common import KindleError


class RangeSource:
    block_size = 64 * 1024

    def __init__(
        self, request, *, cache_budget=4 * 1024 * 1024, full_limit=256 * 1024 * 1024
    ):
        self.request = request
        self.cache_budget = cache_budget
        self.full_limit = full_limit
        self.blocks = OrderedDict()
        self.cached_bytes = self.bytes_received = self.requests = 0
        self.size = None
        self.validator = None
        self.full = None
        self.full_fallback = False

    def close(self):
        if self.full:
            self.full.close()

    def _fetch(self, start):
        end = start + self.block_size - 1
        if self.size is not None:
            end = min(end, self.size - 1)
        headers = {"Range": f"bytes={start}-{end}"}
        if self.validator:
            headers["If-Range"] = self.validator
        response = self.request(headers)
        self.requests += 1
        try:
            encoding = response.headers.get("content-encoding", "identity")
            if encoding.lower() != "identity":
                raise KindleError(
                    "range_encoding", "Codifica Range non supportata.", stage="probe"
                )
            if response.status_code == 200:
                if self.size is not None:
                    raise KindleError(
                        "range_changed",
                        "La risorsa è cambiata durante la lettura.",
                        stage="probe",
                    )
                self.full = tempfile.TemporaryFile()
                for chunk in response.iter_raw():
                    self.bytes_received += len(chunk)
                    if self.bytes_received > self.full_limit:
                        raise KindleError(
                            "range_full_limit",
                            "Risorsa troppo grande per il ripiego completo.",
                            stage="probe",
                        )
                    self.full.write(chunk)
                expected = response.headers.get("content-length")
                if (
                    not self.bytes_received
                    or expected is not None
                    and int(expected) != self.bytes_received
                ):
                    raise KindleError(
                        "range_truncated", "Risorsa incompleta.", stage="probe"
                    )
                self.size = self.bytes_received
                self.full_fallback = True
                return
            match = re.fullmatch(
                r"bytes (\d+)-(\d+)/(\d+)", response.headers.get("content-range", "")
            )
            if response.status_code != 206 or match is None:
                raise KindleError(
                    "range_invalid", "Risposta Range non valida.", stage="probe"
                )
            first, last, total = map(int, match.groups())
            if (
                first != start
                or last != min(end, total - 1)
                or not first <= last < total
                or total > self.full_limit
            ):
                raise KindleError(
                    "range_invalid", "Intervallo restituito non valido.", stage="probe"
                )
            validator = response.headers.get("etag")
            if validator and validator.startswith("W/"):
                validator = None
            validator = validator or response.headers.get("last-modified")
            if not validator:
                raise KindleError(
                    "range_identity_missing",
                    "La risorsa non offre un'identità verificabile per la lettura parziale.",
                    stage="probe",
                )
            if self.size is not None and (
                self.size != total or self.validator != validator
            ):
                raise KindleError(
                    "range_changed",
                    "La risorsa è cambiata durante la lettura.",
                    stage="probe",
                )
            self.size, self.validator = total, validator
            data = bytearray()
            for chunk in response.iter_raw():
                self.bytes_received += len(chunk)
                data.extend(chunk)
                if len(data) > last - first + 1:
                    raise KindleError(
                        "range_invalid", "Risposta Range eccessiva.", stage="probe"
                    )
            if len(data) != last - first + 1:
                raise KindleError(
                    "range_truncated", "Intervallo incompleto.", stage="probe"
                )
            self.blocks[start] = bytes(data)
            self.cached_bytes += len(data)
            while self.cached_bytes > self.cache_budget and len(self.blocks) > 1:
                _, discarded = self.blocks.popitem(last=False)
                self.cached_bytes -= len(discarded)
        finally:
            response.close()

    def read(self, offset, length):
        if offset < 0 or length < 0 or length > self.full_limit:
            raise ValueError("Invalid read")
        if not length:
            return b""
        result = bytearray()
        while length:
            if self.size is not None and offset + length > self.size:
                raise KindleError(
                    "range_bounds", "Riferimento oltre la risorsa.", stage="probe"
                )
            if self.full:
                self.full.seek(offset)
                result.extend(self.full.read(length))
                break
            start = offset // self.block_size * self.block_size
            if start not in self.blocks:
                self._fetch(start)
                if self.full:
                    continue
            if offset + length > self.size:
                raise KindleError(
                    "range_bounds", "Risorsa troppo corta.", stage="probe"
                )
            block = self.blocks[start]
            self.blocks.move_to_end(start)
            count = min(length, len(block) - (offset - start))
            result.extend(block[offset - start : offset - start + count])
            offset += count
            length -= count
        return bytes(result)

    def metrics(self):
        return {
            "resource_bytes": self.size,
            "transferred_bytes": self.bytes_received,
            "requests": self.requests,
            "cache_bytes": self.cached_bytes,
            "full_fallback": self.full_fallback,
        }


class FileRangeSource:
    def __init__(self, path):
        self.path = Path(path)
        self.stream = self.path.open("rb")
        self.size = self.path.stat().st_size
        self.bytes_received = self.requests = 0
        self.full_fallback = False

    def read(self, offset, length):
        if offset < 0 or length < 0 or offset + length > self.size:
            raise ValueError("Invalid file range")
        self.stream.seek(offset)
        data = self.stream.read(length)
        if len(data) != length:
            raise ValueError("Truncated file range")
        self.bytes_received += len(data)
        self.requests += 1
        return data

    def metrics(self):
        return {
            "resource_bytes": self.size,
            "transferred_bytes": self.bytes_received,
            "requests": self.requests,
            "full_fallback": False,
        }

    def close(self):
        self.stream.close()
