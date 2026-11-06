"""Experimental KFX random-access decoder and original-position mapping.

Uses GPLv3+ kfxlib. Reads the container header/index and resolves fragments on
request. This probe does not yet reproduce publisher layout or write to Amazon.
"""

import logging
import struct
import time
from bisect import bisect_right

from .common import KindleError


def quiet_library():
    from kfxlib import set_logger

    logger = logging.Logger("kfx-probe-private", logging.CRITICAL + 1)
    logger.addHandler(logging.NullHandler())
    set_logger(logger)


class ProgressiveKfx:
    def __init__(self, source):
        from kfxlib import YJ_Book
        from kfxlib.ion_binary import IonBinary
        from kfxlib.kfx_container import KfxContainerEntity
        from kfxlib.yj_container import YJFragment, YJFragmentKey, YJFragmentList
        from kfxlib.yj_symbol_catalog import SYSTEM_SYMBOL_TABLE

        quiet_library()
        self.source = source
        self.active_section = None
        self.book = YJ_Book("probe.kfx")
        self.loaded = set()
        started = time.perf_counter()
        prefix = source.read(0, 18)
        signature, version, header_size, info_offset, info_size = struct.unpack(
            "<4sHIII", prefix
        )
        if signature != b"CONT" or version not in (1, 2):
            raise KindleError(
                "probe_kfx_container",
                "Il probe richiede un contenitore KFX CONT leggibile.",
                stage="probe",
            )
        if (
            not 18 <= header_size <= min(source.size, 16 * 1024 * 1024)
            or info_offset + info_size > header_size
        ):
            raise KindleError(
                "probe_kfx_header", "Indice KFX non valido.", stage="probe"
            )
        header = source.read(0, header_size)
        symtab = self.book.symtab
        binary = IonBinary(symtab)
        info = binary.deserialize_single_value(
            header[info_offset : info_offset + info_size]
        )
        if info.get("$411", 0) != 0 or info.get("$410", 0) != 0:
            raise KindleError(
                "probe_kfx_scheme",
                "Schema del contenitore non supportato dal probe.",
                stage="probe",
            )

        def slice_header(offset, length):
            if offset < 0 or length < 0 or offset + length > header_size:
                raise KindleError(
                    "probe_kfx_index",
                    "Intervallo dell'indice non valido.",
                    stage="probe",
                )
            return header[offset : offset + length]

        symbols = None
        if info.get("$416", 0):
            symbols = binary.deserialize_annotated_value(
                slice_header(info["$415"], info["$416"]),
                expect_annotation="$ion_symbol_table",
            )
            for imported in symbols.value.get("imports", []):
                if "max_id" in imported:
                    imported["max_id"] -= len(SYSTEM_SYMBOL_TABLE.symbols)
            symtab.create(symbols.value)
        table = slice_header(info.get("$413", 0), info.get("$414", 0))
        if len(table) % 24:
            raise KindleError(
                "probe_kfx_index", "Indice KFX incompleto.", stage="probe"
            )
        self.entries = []
        for identifier, kind, offset, length in struct.iter_unpack("<IIQQ", table):
            if length < 10 or header_size + offset + length > source.size:
                raise KindleError(
                    "probe_kfx_index",
                    "Frammento KFX fuori dalla risorsa.",
                    stage="probe",
                )
            self.entries.append((identifier, kind, header_size + offset, length))
        owner = self

        class LazyFragments(YJFragmentList):
            def get(self, ftype=None, default=None, fid=None, first=False, all=False):
                kind = ftype
                if isinstance(kind, YJFragmentKey):
                    fid, kind = kind[0], kind[-1]
                scoped = (
                    str(kind) == "$260"
                    and fid is None
                    and owner.active_section is not None
                )
                if scoped:
                    fid = owner.active_section
                for index, (identifier, type_id, offset, length) in enumerate(
                    owner.entries
                ):
                    if index in owner.loaded or str(symtab.get_symbol(type_id)) != str(
                        kind
                    ):
                        continue
                    if fid is not None and str(symtab.get_symbol(identifier)) != str(
                        fid
                    ):
                        continue
                    fragment = KfxContainerEntity(
                        symtab,
                        identifier,
                        type_id,
                        serialized_data=source.read(offset, length),
                    ).deserialize()
                    self.append(fragment)
                    owner.loaded.add(index)
                return super().get(ftype, default, fid=fid, first=first, all=all)

        self.book.fragments = LazyFragments()
        if symbols:
            self.book.fragments.append(YJFragment(symbols))
        self.book.fragments.append(
            YJFragment(ftype="$270", value={"$161": "KFX main", "version": version})
        )
        if info.get("$595", 0):
            capabilities = binary.deserialize_annotated_value(
                slice_header(info["$594"], info["$595"]), expect_annotation="$593"
            )
            self.book.fragments.append(YJFragment(capabilities))
        self.sections = self.book.ordered_section_names()
        if not self.sections:
            raise KindleError(
                "probe_kfx_spine", "Ordine di lettura KFX assente.", stage="probe"
            )
        self.bootstrap_ms = (time.perf_counter() - started) * 1000

    def section_chunks(self, index):
        if not 0 <= index < len(self.sections):
            raise IndexError("Section index")
        original = self.book.ordered_section_names
        self.active_section = self.sections[index]
        self.book.__dict__.pop(
            "_cached_is_illustrated_layout_conditional_structure", None
        )
        self.book.ordered_section_names = lambda: [self.sections[index]]
        try:
            if (
                self.book.has_illustrated_layout_conditional_page_template
                or self.book.is_fixed_layout
            ):
                raise KindleError(
                    "probe_kfx_layout",
                    "Il probe progressivo iniziale supporta testo rifluibile senza layout condizionale.",
                    stage="probe",
                )
            chunks = self.book.collect_content_position_info()
        finally:
            self.book.ordered_section_names = original
        return chunks

    def original_positions(self, chunks):
        positions = self.book.collect_position_map_info()
        by_eid = {}
        for entry in positions:
            by_eid.setdefault(entry.eid, []).append(entry)
        result = []
        for chunk in chunks:
            if not chunk.text:
                continue
            candidates = by_eid.get(chunk.eid, [])
            match = next(
                (
                    entry
                    for entry in candidates
                    if entry.eid_offset
                    <= chunk.eid_offset
                    < entry.eid_offset + max(1, entry.length)
                ),
                None,
            )
            if match is None:
                raise KindleError(
                    "probe_position_unmapped",
                    "Posizione originale non risolta; sincronizzazione disabilitata per questa sezione.",
                    stage="probe",
                )
            result.append(
                {
                    "position": match.pid + chunk.eid_offset - match.eid_offset,
                    "eid": str(chunk.eid),
                    "offset": chunk.eid_offset,
                    "text": chunk.text,
                    "length": chunk.length,
                }
            )
        return result


def utf16_length(text):
    return len(text.encode("utf-16-le")) // 2


class PositionMap:
    """Map unmodified text offsets to original Kindle positions, never percent."""

    def __init__(self, chunks):
        self.chunks = sorted(chunks, key=lambda item: item["position"])
        self.starts = [item["position"] for item in self.chunks]

    def from_text(self, index, utf16_offset):
        chunk = self.chunks[index]
        if len(chunk["text"]) != chunk["length"]:
            raise ValueError("Text length differs from original positions")
        units = 0
        for offset, character in enumerate(chunk["text"]):
            if units == utf16_offset:
                return chunk["position"] + offset
            units += 2 if ord(character) > 0xFFFF else 1
        if utf16_offset < 0 or units != utf16_offset:
            raise ValueError("Offset is outside mapped text")
        raise ValueError("Offset is at the end of mapped text")

    def to_text(self, position):
        index = bisect_right(self.starts, position) - 1
        if index < 0:
            raise ValueError("Position is outside mapped text")
        chunk = self.chunks[index]
        offset = position - chunk["position"]
        if offset >= min(chunk["length"], len(chunk["text"])):
            raise ValueError("Position is outside mapped text")
        return index, utf16_length(chunk["text"][:offset])
