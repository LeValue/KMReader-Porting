#!/usr/bin/env python3
"""Benchmark a local EPUB against bundled assets, optionally from an older tree.

Example: python3 tool/epub_benchmark.py book.epub --chapter OEBPS/one.xhtml
Use --assets /tmp/old-assets --capture to reproduce the old Windows turn path.
Only loopback resources are served; the EPUB is never uploaded.
"""
import argparse
import hashlib
import json
import mimetypes
import posixpath
import statistics
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from playwright.sync_api import sync_playwright


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('epub', type=Path)
    parser.add_argument('--chapter', required=True, help='Archive-relative XHTML path')
    parser.add_argument('--assets', type=Path, default=Path('assets/epub'))
    parser.add_argument('--capture', action='store_true', help='Reproduce native screenshot cost before each animated turn')
    parser.add_argument('--count', type=int, default=12)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.count < 4:
        parser.error('--count must be at least 4 (two warm-up turns are discarded)')
    archive = zipfile.ZipFile(args.epub)
    opf = next(e.attrib['full-path'] for e in ET.fromstring(archive.read('META-INF/container.xml')).iter() if e.tag.endswith('rootfile'))
    archive.getinfo(args.chapter)
    assets = {name: (args.assets / name).read_bytes() for name in ['epub.min.js', 'jszip.min.js', 'reader.js', 'reader.css']}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def do_GET(self):
            path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
            try:
                if path == '/reader/':
                    data = b'<html><head><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="reader.css"></head><body><div id="viewer"></div><script src="jszip.min.js"></script><script src="epub.min.js"></script><script src="reader.js"></script></body></html>'
                    mime = 'text/html'
                elif path.startswith('/reader/'):
                    data = assets[path[8:]]
                    mime = 'text/css' if path.endswith('.css') else 'application/javascript'
                else:
                    data = archive.read(path.removeprefix('/book/'))
                    mime = 'application/xhtml+xml' if path.endswith('.xhtml') else 'application/oebps-package+xml' if path.endswith('.opf') else mimetypes.guess_type(path)[0] or 'application/octet-stream'
            except KeyError:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    preferences = {'flow': 'paged', 'font': 'publisher', 'theme': 'sepia', 'animate': True, 'advancedLayout': True, 'fontWeight': 0, 'fontSize': 19, 'lineHeight': 1.65, 'margin': 24, 'columns': 0, 'alignment': 'publisher', 'paragraphSpacing': .5, 'indent': 0, 'letterSpacing': 0, 'wordSpacing': 0, 'transition': 'slide', 'tapScroll': 80}
    results = []
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True, args=['--no-sandbox'])
            engine = browser.version
            for width, height in [(1044, 720), (390, 780)]:
                for style in ['none', 'slide']:
                    page = browser.new_page(viewport={'width': width, 'height': height})
                    errors = []
                    page.on('pageerror', lambda error: errors.append(str(error)))
                    page.add_init_script("window.events=[];addEventListener('readerEvent',e=>events.push({...e.detail,at:performance.now()}));")
                    page.goto(base + '/reader/')
                    start = time.perf_counter()
                    page.evaluate('(c)=>reader.open(c)', {'url': base + '/book/' + opf, 'nonce': 'benchmark', 'direction': 'ltr', 'language': 'en', 'preferences': preferences, 'href': posixpath.relpath(args.chapter, posixpath.dirname(opf))})
                    opened = (time.perf_counter() - start) * 1000
                    cdp = page.context.new_cdp_session(page)
                    times, first, captures = [], [], []
                    for i in range(args.count):
                        start = time.perf_counter()
                        value = {'delta': 1, 'style': style}
                        if args.capture and style != 'none':
                            value['snapshot'] = 'data:image/jpeg;base64,' + cdp.send('Page.captureScreenshot', {'format': 'jpeg', 'quality': 85, 'captureBeyondViewport': False})['data']
                        captured = (time.perf_counter() - start) * 1000
                        out = page.evaluate('''async v=>{const at=performance.now(),old=reader.position().start.cfi,index=events.length;
                          await reader.turn(v);const e=events.slice(index).find(e=>e.type==='position'&&e.changed);
                          return {first:e?e.at-at:null,changed:reader.position().start.cfi!==old};}''', value)
                        elapsed = (time.perf_counter() - start) * 1000
                        assert out['changed'] and out['first'] is not None, (width, style, i, out)
                        if i > 1:
                            times.append(elapsed)
                            first.append(out['first'])
                            captures.append(captured)
                    assert not errors, errors
                    result = {'width': width, 'height': height, 'style': style, 'open_ms': round(opened, 1), 'turn_median_ms': round(statistics.median(times), 1), 'turn_max_ms': round(max(times), 1), 'first_locator_median_ms': round(statistics.median(first), 1), 'capture_median_ms': round(statistics.median(captures), 1)}
                    print(json.dumps(result), flush=True)
                    results.append(result)
                    page.evaluate('reader.destroy()')
                    page.close()
            browser.close()
        report = {'epub_sha256': hashlib.sha256(args.epub.read_bytes()).hexdigest(), 'epub_bytes': args.epub.stat().st_size, 'chapter': args.chapter, 'engine': engine, 'capture': args.capture, 'samples_per_case': args.count - 2, 'results': results}
        if args.output:
            args.output.write_text(json.dumps(report, indent=2) + '\n')
    finally:
        server.shutdown()
        server.server_close()
        archive.close()


if __name__ == '__main__':
    main()
