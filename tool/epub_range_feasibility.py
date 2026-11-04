#!/usr/bin/env python3
"""Research probe: shipped EPUB JS over a lazy ZIP/HTTP Range resource host.

Generated public fixture only; no Amazon credentials or service calls. This is
not a production ZIP client, Kindle connector, or a native-device FPS benchmark.
"""
import argparse
from collections import OrderedDict
import io
import json
from pathlib import Path
import random
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen
from urllib.parse import unquote, urlsplit
import zipfile

from PIL import Image
from playwright.sync_api import sync_playwright


class RemoteFile(io.RawIOBase):
    def __init__(self, url):
        self.url, self.position = url, 0
        self.cache, self.full = OrderedDict(), None
        self.transferred = self.requests = 0
        with urlopen(Request(url, method='HEAD'), timeout=10) as response:
            self.length = int(response.headers['Content-Length'])
            self.etag = response.headers['ETag']

    def seekable(self): return True
    def readable(self): return True
    def tell(self): return self.position

    def seek(self, offset, whence=0):
        self.position = offset + (0 if whence == 0 else self.position if whence == 1 else self.length)
        if not 0 <= self.position <= self.length:
            raise ValueError('Seek outside publication')
        return self.position

    def read(self, size=-1):
        end = self.length if size < 0 else min(self.length, self.position + size)
        if end <= self.position: return b''
        start = self.position
        if self.full is not None:
            self.position = end
            return self.full[start:end]
        parts, pos = [], start
        while pos < end:
            block = pos // 65536
            if block not in self.cache:
                first, last = block * 65536, min((block + 1) * 65536, self.length) - 1
                request = Request(self.url, headers={'Range': f'bytes={first}-{last}', 'Accept-Encoding': 'identity'})
                with urlopen(request, timeout=10) as response:
                    data = response.read()
                    self.requests += 1
                    self.transferred += len(data)
                    if response.headers.get('ETag') != self.etag:
                        raise ValueError('Publication revision changed')
                    if response.status == 200:
                        if len(data) != self.length: raise ValueError('Truncated full response')
                        self.full = data
                        self.position = end
                        return data[start:end]
                    if response.status != 206 or response.headers.get('Content-Range') != f'bytes {first}-{last}/{self.length}':
                        raise ValueError('Invalid partial response')
                    if len(data) != last - first + 1: raise ValueError('Truncated range')
                    self.cache[block] = data
                    while len(self.cache) > 128: self.cache.popitem(last=False)
            self.cache.move_to_end(block)
            data = self.cache[block]
            offset = pos % 65536
            chunk = data[offset:min(len(data), offset + end - pos)]
            parts.append(chunk)
            pos += len(chunk)
        self.position = end
        return b''.join(parts)


def fixture():
    rng = random.Random(42)
    resources = {
        'mimetype': b'application/epub+zip',
        'META-INF/container.xml': b'<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>',
        'OPS/package.opf': ('<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">range-probe</dc:identifier>'
            '<dc:title>Progressive publication probe</dc:title><dc:language>en</dc:language></metadata><manifest>'
            '<item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>' + ''.join(
                f'<item id="c{i}" href="c{i}.xhtml" media-type="application/xhtml+xml"/>'
                f'<item id="img{i}" href="img{i}.png" media-type="image/png"/>' for i in range(12)) +
            '</manifest><spine>' + ''.join(f'<itemref idref="c{i}"/>' for i in range(12)) + '</spine></package>').encode(),
        'OPS/nav.xhtml': ('<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
            '<body><nav epub:type="toc"><ol>' + ''.join(f'<li><a href="c{i}.xhtml">Chapter {i}</a></li>' for i in range(12)) +
            '</ol></nav></body></html>').encode(),
    }
    for i in range(12):
        resources[f'OPS/c{i}.xhtml'] = ('<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head>'
            f'<body><h1>CHAPTER {i}</h1>' + ''.join(f'<p>Passage {n}: the reader loads this chapter without downloading the entire publication. '
                'Content remains in the KMReader engine with its own typography and navigation.</p>' for n in range(50)) +
            f'<img src="img{i}.png" width="512" height="768"/></body></html>').encode()
        picture = Image.frombytes('RGB', (512, 768), rng.randbytes(512 * 768 * 3))
        image = io.BytesIO()
        picture.save(image, format='PNG', compress_level=1)
        resources[f'OPS/img{i}.png'] = image.getvalue()
    packed = io.BytesIO()
    with zipfile.ZipFile(packed, 'w') as archive:
        for name, data in resources.items():
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED if name == 'mimetype' else zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
    return packed.getvalue(), resources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--screenshots', type=Path)
    args = parser.parse_args()
    packed, original = fixture()
    assets = Path(__file__).resolve().parent.parent / 'assets/epub'
    publications = {}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *unused): pass
        def do_HEAD(self): self.respond(True)
        def do_GET(self): self.respond(False)

        def respond(self, head):
            path = unquote(urlsplit(self.path).path)
            if path in ['/range/book.epub', '/full/book.epub']:
                start, end = 0, len(packed) - 1
                partial = path.startswith('/range/') and self.headers.get('Range') is not None
                if partial:
                    match = re.fullmatch(r'bytes=(\d+)-(\d+)', self.headers['Range'])
                    if not match: self.send_error(416); return
                    start, end = map(int, match.groups())
                self.send_response(206 if partial else 200)
                self.send_header('Content-Type', 'application/epub+zip')
                self.send_header('Content-Length', str(end - start + 1))
                self.send_header('ETag', '"immutable-generated-fixture"')
                if partial: self.send_header('Content-Range', f'bytes {start}-{end}/{len(packed)}')
                self.end_headers()
                if not head: self.wfile.write(packed[start:end + 1])
                return
            if path == '/reader/':
                data = b'<html><head><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="reader.css"></head><body><div id="viewer"></div><script src="epub.min.js"></script><script src="reader.js"></script></body></html>'
                mime = 'text/html'
            elif path.startswith('/reader/') and path.rsplit('/', 1)[-1] in ['reader.js', 'epub.min.js', 'reader.css']:
                name = path.rsplit('/', 1)[-1]
                data = (assets / name).read_bytes()
                mime = 'text/css' if name.endswith('.css') else 'application/javascript'
            elif path.startswith('/publication/'):
                _, _, case, name = path.split('/', 3)
                source, archive, trace = publications[case]
                if name not in original: self.send_error(404); return
                trace.add(name)
                data = archive.read(name)
                assert data == original[name], 'Wrong ZIP resource bytes'
                mime = 'image/png' if name.endswith('.png') else 'application/oebps-package+xml' if name.endswith('.opf') else 'application/xhtml+xml'
            else: self.send_error(404); return
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'private, max-age=3600')
            self.end_headers()
            if not head: self.wfile.write(data)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    report = {'purpose': 'Transport/resource feasibility with generated unencrypted EPUB; not Amazon access or device FPS',
              'fixtureBytes': len(packed), 'chapters': 12, 'cases': []}
    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=True, args=['--no-sandbox'])
            report['browser'] = browser.version
            for case in ['range', 'full']:
                source = RemoteFile(f'{base}/{case}/book.epub')
                archive, trace = zipfile.ZipFile(source), set()
                assert archive.read('META-INF/container.xml') == original['META-INF/container.xml']
                publications[case] = source, archive, trace
                page = browser.new_page(viewport={'width': 393, 'height': 844})
                errors = []
                page.on('pageerror', lambda error: errors.append(str(error)))
                page.goto(base + '/reader/')
                preferences = dict(flow='paged', font='serif', theme='white', animate=True, advancedLayout=True,
                    fontSize=19, lineHeight=1.65, margin=24, columns=1, alignment='publisher', paragraphSpacing=.5,
                    indent=0, letterSpacing=0, wordSpacing=0, fontWeight=0, transition='none', tapScroll=80)
                page.evaluate('(c)=>reader.open(c)', dict(url=f'{base}/publication/{case}/OPS/package.opf',
                    nonce='range-probe', preferences=preferences, direction='ltr', href='c0.xhtml'))
                assert page.frames[1].locator('body').inner_text().startswith('CHAPTER 0')
                if args.screenshots:
                    args.screenshots.mkdir(parents=True, exist_ok=True)
                    page.screenshot(path=str(args.screenshots / f'{case}-first.png'))
                first = {'bytes': source.transferred, 'requests': source.requests, 'resources': sorted(trace)}
                page.evaluate("reader.display('c1.xhtml')")
                assert page.frames[1].locator('body').inner_text().startswith('CHAPTER 1')
                second = {'bytes': source.transferred, 'requests': source.requests}
                before = source.transferred
                page.evaluate("reader.display('c0.xhtml')")
                assert source.transferred == before, 'Revisit did not reuse resource/block caches'
                assert not errors, errors
                if case == 'range':
                    assert first['bytes'] < len(packed) / 4
                    assert 'OPS/img11.png' not in trace and 'OPS/c11.xhtml' not in trace
                else: assert first['bytes'] == len(packed)
                report['cases'].append({'case': case, 'firstReady': first, 'secondChapter': second,
                    'revisitAdditionalBytes': source.transferred - before, 'fullFileFallback': source.full is not None})
                page.evaluate('reader.destroy()')
                page.close()
                archive.close()
                source.close()
            browser.close()
    finally:
        server.shutdown()
        server.server_close()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__': main()
