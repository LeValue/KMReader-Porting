"""Lossless APK transport using exact ZIP payloads from verified CI artifacts.

The signed APK is never repacked or signed remotely. Its original headers,
signing block and any changed payloads are literals; unchanged compressed ZIP
payloads are copied from the exact CI APK. Both input and output hashes are
checked, followed by the normal certificate/provenance checks at delivery.
"""

import hashlib
import json
import lzma
import mmap
from pathlib import Path
import struct
import zipfile

MAX_SIZE = 512 * 1024 * 1024
MAGIC = b"KMReaderAPKDelta1\n"


def _payload(stream, entry):
    start = entry.header_offset
    header = stream[start:start + 30]
    if len(header) != 30 or header[:4] != b"PK\x03\x04":
        raise ValueError("Invalid ZIP local header")
    name, extra = struct.unpack_from("<HH", header, 26)
    offset = start + 30 + name + extra
    if offset + entry.compress_size > len(stream):
        raise ValueError("ZIP payload outside archive")
    return offset, entry.compress_size


def make_delta(base_path, target_path):
    with open(base_path, "rb") as base_file, open(target_path, "rb") as target_file:
        with mmap.mmap(base_file.fileno(), 0, access=mmap.ACCESS_READ) as base, mmap.mmap(target_file.fileno(), 0, access=mmap.ACCESS_READ) as target:
            if len(base) > MAX_SIZE or len(target) > MAX_SIZE:
                raise ValueError("APK exceeds transport size limit")
            with zipfile.ZipFile(base_path) as before, zipfile.ZipFile(target_path) as after:
                available = {e.filename: _payload(base, e) for e in before.infolist()}
                spans = sorted((_payload(target, e), e.filename) for e in after.infolist())
            cursor = 0
            literals = bytearray()
            segments = []

            def literal(start, end):
                if start < end:
                    offset = len(literals)
                    literals.extend(target[start:end])
                    segments.append(["literal", offset, end - start])

            for (offset, length), name in spans:
                previous = available.get(name)
                if offset < cursor or not length or previous is None or previous[1] != length:
                    continue
                old_offset = previous[0]
                if hashlib.sha256(base[old_offset:old_offset + length]).digest() != hashlib.sha256(target[offset:offset + length]).digest():
                    continue
                literal(cursor, offset)
                segments.append(["base", old_offset, length])
                cursor = offset + length
            literal(cursor, len(target))
            metadata = {
                "schema": 1,
                "base_sha256": hashlib.sha256(base).hexdigest(),
                "result_sha256": hashlib.sha256(target).hexdigest(),
                "size": len(target),
                "segments": segments,
            }
            header = json.dumps(metadata, separators=(",", ":")).encode()
            return lzma.compress(MAGIC + struct.pack("<I", len(header)) + header + literals)


def apply_delta(base_path, packed, expected_sha256):
    decoder = lzma.LZMADecompressor()
    data = decoder.decompress(packed, max_length=MAX_SIZE + 1)
    if len(data) > MAX_SIZE or not decoder.eof or decoder.unused_data or not data.startswith(MAGIC) or len(data) < len(MAGIC) + 4:
        raise ValueError("Invalid or oversized APK transport")
    start = len(MAGIC)
    header_size = struct.unpack_from("<I", data, start)[0]
    start += 4
    if header_size > 4 * 1024 * 1024 or start + header_size > len(data):
        raise ValueError("Invalid APK transport header")
    metadata = json.loads(data[start:start + header_size])
    literals = memoryview(data)[start + header_size:]
    if metadata.get("schema") != 1 or metadata.get("result_sha256") != expected_sha256:
        raise ValueError("Unexpected signed APK digest")
    size = metadata.get("size")
    segments = metadata.get("segments")
    if type(size) is not int or not 0 < size <= MAX_SIZE or not isinstance(segments, list) or len(segments) > 100000:
        raise ValueError("Invalid APK transport shape")
    base = Path(base_path).read_bytes()
    if len(base) > MAX_SIZE or hashlib.sha256(base).hexdigest() != metadata.get("base_sha256"):
        raise ValueError("CI base APK hash mismatch")
    result = bytearray()
    for segment in segments:
        if not isinstance(segment, list) or len(segment) != 3:
            raise ValueError("Invalid APK segment")
        kind, offset, length = segment
        source = base if kind == "base" else literals if kind == "literal" else None
        if source is None or type(offset) is not int or type(length) is not int or offset < 0 or length < 0 or offset + length > len(source) or len(result) + length > size:
            raise ValueError("APK segment outside verified input")
        result.extend(source[offset:offset + length])
    if len(result) != size or hashlib.sha256(result).hexdigest() != expected_sha256:
        raise ValueError("Reconstructed APK hash mismatch")
    return result
