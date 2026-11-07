"""Offline worker for the standalone companion, never imported by Flutter.

Uses John Howell's GPLv3+ kfxlib; the companion binary and corresponding source
are distributed under GPLv3+. The application's own MIT license is unchanged.
Only content files enter this worker, never an Amazon session or device key.
"""

import logging
from pathlib import Path


def convert_kfx(source: Path, output: Path):
    try:
        from kfxlib import KFXDRMError, set_logger
    except ImportError:
        return 6

    logger = logging.Logger("kindle-kfx-private", level=logging.CRITICAL + 1)
    logger.addHandler(logging.NullHandler())
    logger.propagate = False
    set_logger(logger)
    try:
        from .mapped_kfx import mapped_epub

        data = mapped_epub(source)
        output.write_bytes(data)
        return 0
    except KFXDRMError:
        return 4
    except Exception:
        # Third-party errors may contain passages or private metadata. The
        # parent uses a fixed reason code and validates any generated EPUB.
        return 5
