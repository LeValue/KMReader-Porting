"""Faithful KFX conversion with verified original-position markers.

Uses John Howell's GPLv3+ kfxlib. Shared by the desktop companion and the
on-demand Android conversion worker; never needs an Amazon credential.
"""

import io
import json
import zipfile
from collections import defaultdict


def mapped_epub(source):
    from kfxlib import YJ_Book
    from kfxlib.yj_to_epub import KFX_EPUB
    from lxml import etree

    book = YJ_Book(str(source))
    book.decode_book()
    primary_acr = book.get_asset_id()
    by_eid = defaultdict(list)
    for chunk in book.collect_content_position_info():
        if chunk.text and len(chunk.text) == chunk.length:
            by_eid[str(chunk.eid)].append(chunk)
    expected = {}
    elements = {}

    class MappedEpub(KFX_EPUB):
        def process_position(self, eid, offset, element):
            result = super().process_position(eid, offset, element)
            chunk = next(
                (
                    item
                    for item in by_eid.get(str(eid), [])
                    if item.eid_offset == offset
                ),
                None,
            )
            if chunk is not None:
                elements.setdefault(element, (chunk.pid, chunk.text))
            return result

        def beautify_html(self, book_part):
            super().beautify_html(book_part)
            # Record positions after consolidation and style/layout fixups.
            # Earlier attributes would prevent upstream span consolidation and
            # needlessly increase the reader's DOM size.
            for element in book_part.body().iter():
                candidate = elements.get(element)
                if candidate is None or "".join(element.itertext()) != candidate[1]:
                    continue
                marker = f"km-kindle-{len(expected)}"
                element.set("data-kmreader-kindle-marker", marker)
                expected[marker] = candidate

    converter = MappedEpub(book)
    converted = converter.decompile_to_epub()
    entries = []
    output = io.BytesIO()
    with (
        zipfile.ZipFile(io.BytesIO(converted)) as original,
        zipfile.ZipFile(output, "w") as prepared,
    ):
        for info in original.infolist():
            data = original.read(info)
            if info.filename.endswith((".xhtml", ".html")):
                document = etree.fromstring(data)
                for element in document.iter():
                    marker = element.attrib.pop("data-kmreader-kindle-marker", None)
                    if marker is None or marker not in expected:
                        continue
                    position, text = expected[marker]
                    # Styling, footnotes and layout fixups may change the
                    # subtree. Only exact, unnormalised matches are mapped.
                    actual = "".join(element.itertext())
                    if actual != text:
                        continue
                    identifier = element.get("id") or marker
                    element.set("id", identifier)
                    element.set("data-kmreader-kindle-position", str(position))
                    element.set("data-kmreader-kindle-length", str(len(text)))
                    entries.append(
                        {
                            "path": info.filename,
                            "id": identifier,
                            "position": position,
                            "length": len(text),
                        }
                    )
                data = etree.tostring(document, encoding="utf-8", xml_declaration=True)
            prepared.writestr(info, data)
        # This is a book-local map. No account ID, access token, private key or
        # external URL belongs in the EPUB or its mapping metadata.
        entries.sort(key=lambda item: (item["position"], -item["length"], item["path"]))
        prepared.writestr(
            "META-INF/kmreader-kindle.json",
            json.dumps(
                {
                    "schema": 1,
                    "position_units": "unicode_scalars",
                    "primary_acr": str(primary_acr) if primary_acr else None,
                    "container_acrs": sorted(
                        {
                            str(container.container_id)
                            for container in book.yj_containers
                            if getattr(container, "container_id", None)
                        }
                    ),
                    "entries": entries,
                },
                separators=(",", ":"),
            ).encode(),
            compress_type=zipfile.ZIP_DEFLATED,
        )
    book.final_actions()
    return output.getvalue()
