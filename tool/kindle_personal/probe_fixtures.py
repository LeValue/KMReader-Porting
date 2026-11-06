"""Generated test text only; no copied Kindle books or account data."""

import json
import tempfile
from pathlib import Path


def synthetic_progressive_kfx(sections=16):
    from kfxlib import YJ_Book
    from kfxlib.kfx_container import KfxContainer
    from kfxlib.yj_container import YJFragment
    from .kfx_progressive import quiet_library

    quiet_library()
    names = [f"section_{index}" for index in range(sections)]
    content = (
        "'$258'::{ '$153':\"KMReader progressive synthetic\", '$10':\"it\", '$251':\"PDOC\", '$169':[{ '$178':'$351', '$170':["
        + ",".join(repr(name) for name in names)
        + "] }] }\n"
    )
    for index, name in enumerate(names):
        text = (
            f"Capitolo sintetico {index}. Accenti: città, e\u0301. Emoji: 😀. "
        ) * 300
        content += f"'{name}'::'$260'::{{ '$174':'{name}', '$141':[{{ '$159':'$270', '$156':'$323', '$176':'story_{index}' }}] }}\n"
        content += f"'story_{index}'::'$259'::{{ '$176':'story_{index}', '$146':[{{ '$155':{index + 1}, '$159':'$269', '$145':{json.dumps(text, ensure_ascii=False)} }}] }}\n"
    with tempfile.TemporaryDirectory() as temporary:
        source = Path(temporary) / "book.ion"
        source.write_text(content, encoding="utf-8")
        book = YJ_Book(str(source))
        book.decode_book(skip_book_checks=True)
        for name in [*names, *[f"story_{index}" for index in range(sections)]]:
            book.symtab.create_local_symbol(name)
        book.create_position_map(book.collect_content_position_info())
        book.fragments.append(YJFragment(book.symtab.create_import()))
        return KfxContainer(book.symtab, fragments=book.fragments).serialize()
