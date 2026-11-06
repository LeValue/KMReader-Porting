"""Fetch only cover/metadata fragments using temporary content URLs.

No device key, bearer token or account cookie enters this module or worker.
URLs stay in private process messages; errors never include them.
"""

import base64
import io
from urllib.parse import urlsplit

from .common import KindleError
from .kfx_progressive import ProgressiveKfx, quiet_library
from .range_source import RangeSource

MAX_TRANSFER = 4 * 1024 * 1024


def allowed_cover_url(value):
    uri = urlsplit(value)
    host = (uri.hostname or "").lower()
    if host == "127.0.0.1":
        import re

        return (
            uri.scheme == "http"
            and uri.port is not None
            and uri.port > 1024
            and not uri.username
            and not uri.query
            and not uri.fragment
            and re.fullmatch(r"/kindle-cover/[A-Za-z0-9_-]{32}/[0-5]", uri.path)
            is not None
        )
    return (
        uri.scheme == "https"
        and uri.port in (None, 443)
        and not uri.username
        and (
            host.endswith(".cloudfront.net")
            or host.endswith(".amazonaws.com")
            or host
            in {
                "m.media-amazon.com",
                "images-na.ssl-images-amazon.com",
                "images-eu.ssl-images-amazon.com",
            }
        )
    )


def thumbnail(data):
    from PIL import Image, ImageOps

    if len(data) > MAX_TRANSFER:
        raise ValueError("Cover size")
    with Image.open(io.BytesIO(data)) as image:
        image = ImageOps.exif_transpose(image)
        image.thumbnail((480, 720))
        background = Image.new("RGB", image.size, "white")
        if image.mode == "RGBA":
            background.paste(image, mask=image.getchannel("A"))
        else:
            background.paste(image.convert("RGB"))
        output = io.BytesIO()
        background.save(output, "JPEG", quality=85, optimize=True)
        return output.getvalue()


def extract_cover(sources):
    """Metadata only: never enumerates or lays out the reading sections."""
    from kfxlib.yj_container import YJFragmentList

    readers = []
    for source in sources:
        try:
            readers.append(ProgressiveKfx(source, metadata_only=True))
        except KindleError:
            continue
    if not readers:
        return {}

    class Combined(YJFragmentList):
        def get(self, ftype=None, default=None, fid=None, first=False, all=False):
            found = []
            for fragments in collections:
                value = fragments.get(ftype, None, fid=fid, first=first, all=all)
                if value is not None:
                    if not all:
                        return value
                    found.extend(value)
            return found if all and found else default

    collections = [reader.book.fragments for reader in readers]
    book = readers[0].book
    book.fragments = Combined()
    result = {}
    data = book.get_cover_image_data()
    if data:
        result["image"] = base64.b64encode(thumbnail(data[1])).decode("ascii")
    pages = book.get_page_count()
    if pages and 0 < pages < 1000000:
        result["pages"] = pages
        result["estimated"] = False
    try:
        positions = book.collect_position_map_info()
        end = max((entry.pid + entry.length for entry in positions), default=0)
    except Exception:
        end = 0
    if end > 0:
        result["characters"] = end
        if not pages:
            result["pages"] = max(1, (end + 1023) // 1024)
            result["estimated"] = True
    return result


def remote_cover(urls):
    import httpx

    quiet_library()
    transferred = 0
    client = httpx.Client(
        trust_env=False,
        timeout=25,
        follow_redirects=False,
        headers={"Accept-Encoding": "identity"},
    )
    sources = []

    class Bounded:
        def __init__(self, response):
            self.response = response
            self.status_code = response.status_code
            self.headers = response.headers

        def iter_raw(self):
            nonlocal transferred
            for chunk in self.response.iter_raw():
                transferred += len(chunk)
                if transferred > MAX_TRANSFER:
                    raise ValueError("Cover transfer limit")
                yield chunk

        def close(self):
            self.response.close()

    def request(url, headers):
        for _ in range(6):
            if not allowed_cover_url(url):
                raise ValueError("Cover address")
            response = client.send(
                client.build_request("GET", url, headers=headers), stream=True
            )
            if not response.is_redirect:
                return Bounded(response)
            location = str(response.url.join(response.headers.get("location", "")))
            response.close()
            url = location
        raise ValueError("Cover redirects")

    try:
        for url in urls[:6]:
            if not allowed_cover_url(url):
                continue
            source = RangeSource(
                lambda headers, url=url: request(url, headers), full_limit=2 * 1024**3
            )
            sources.append(source)
        result = extract_cover(sources)
        return {**result, "transferred": transferred}
    finally:
        for source in sources:
            source.close()
        client.close()
