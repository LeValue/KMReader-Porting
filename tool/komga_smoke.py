#!/usr/bin/env python3
"""Run the Dart client against a real, disposable Komga 1.29.1 instance."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
import zlib


def png(color):
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 64, 96, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress((b'\x00' + bytes(color) * 64) * 96)) + chunk(b'IEND', b''))


def epub(path):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('mimetype', 'application/epub+zip')
        z.writestr('META-INF/container.xml', '<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        z.writestr('OPS/package.opf', '''<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:1666cb43-b3a1-4676-b832-1452ce968c9f</dc:identifier><dc:title>Synthetic EPUB</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-01-01T00:00:00Z</meta></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>''')
        for name, title in [('one','First Chapter'), ('two','Second Chapter')]:
            z.writestr(f'OPS/{name}.xhtml', f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title></head><body><h1>{title}</h1><p>Hello KMReader.</p></body></html>')
        z.writestr('OPS/nav.xhtml', '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="one.xhtml">First Chapter</a></li><li><a href="two.xhtml">Second Chapter</a></li></ol></nav></body></html>')


def pdf(path):
    stream = b'BT /F1 20 Tf 30 330 Td (Hello KMReader) Tj ET'
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
               b'<< /Length ' + str(len(stream)).encode() + b' >>\nstream\n' + stream + b'\nendstream',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    output = b'%PDF-1.4\n'; offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(output)); output += f'{i} 0 obj\n'.encode() + obj + b'\nendobj\n'
    start = len(output)
    output += f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode()
    output += b''.join(f'{offset:010d} 00000 n \n'.encode() for offset in offsets[1:])
    output += f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode()
    path.write_bytes(output)


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--jar', type=Path, required=True)
    parser.add_argument('--startup-timeout', type=int, default=300)
    args = parser.parse_args()
    assert hashlib.sha256(args.jar.read_bytes()).hexdigest() == 'e9cafae1ec6d0d117c2375fff9ecb737ed384eede2afea9716bcb555d96ea834', 'Expected official Komga 1.29.1 SHA256'
    with tempfile.TemporaryDirectory(prefix='kmreader-live-') as td:
        root = Path(td); library = root/'library'; series = library/'Synthetic Series'; series.mkdir(parents=True)
        with zipfile.ZipFile(series/'Synthetic Comic.cbz', 'w') as z:
            for i, color in enumerate([(255,0,0),(0,255,0),(0,0,255)],1): z.writestr(f'{i:03d}.png', png(color))
            z.writestr('ComicInfo.xml','<ComicInfo><Title>Synthetic Comic</Title><Series>Synthetic Series</Series><Number>1</Number></ComicInfo>')
        epub(series/'Synthetic EPUB.epub'); pdf(series/'Synthetic PDF.pdf')
        with socket.socket() as sock: sock.bind(('127.0.0.1',0)); port = sock.getsockname()[1]
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({})); authorization = None
        def request(path, method='GET', body=None, headers=None):
            h = dict(headers or {})
            if authorization: h['Authorization'] = authorization
            data = json.dumps(body).encode() if body is not None else None
            if data is not None: h['Content-Type'] = 'application/json'
            with opener.open(urllib.request.Request(f'http://127.0.0.1:{port}{path}',data=data,headers=h,method=method),timeout=60 if path=='/api/v1/claim' and method=='POST' else 30) as r:
                data = r.read(); return json.loads(data) if data else None
        with (root/'server.log').open('w') as log:
            server = subprocess.Popen(['java','-Xmx768m','-XX:ActiveProcessorCount=2','-jar',str(args.jar.resolve()),
                '--server.address=127.0.0.1',f'--server.port={port}',f'--komga.config-dir={root/"data"}'],stdout=log,stderr=subprocess.STDOUT)
            try:
                deadline=time.monotonic()+args.startup_timeout
                while True:
                    if server.poll() is not None: raise RuntimeError('Komga exited before readiness')
                    try: request('/api/v1/claim'); break
                    except (OSError,urllib.error.URLError):
                        if time.monotonic()>deadline: raise TimeoutError('Komga startup timed out')
                        time.sleep(1)
                email,password='reader@example.invalid',secrets.token_urlsafe(32)
                request('/api/v1/claim','POST',headers={'X-Komga-Email':email,'X-Komga-Password':password})
                authorization='Basic '+base64.b64encode(f'{email}:{password}'.encode()).decode()
                payload={k:False for k in ['analyzeDimensions','convertToCbz','emptyTrashAfterScan','hashFiles','hashKoreader','hashPages','importBarcodeIsbn','importComicInfoBook','importComicInfoCollection','importComicInfoReadList','importComicInfoSeries','importComicInfoSeriesAppendVolume','importEpubBook','importEpubSeries','importLocalArtwork','importMylarSeries','repairExtensions','scanCbx','scanEpub','scanForceModifiedTime','scanOnStartup','scanPdf']}
                payload.update(name='Synthetic Library',root=str(library),scanCbx=True,scanEpub=True,scanPdf=True,scanOnStartup=True,analyzeDimensions=True,importComicInfoBook=True,importEpubBook=True,scanDirectoryExclusions=[],scanInterval='DISABLED',seriesCover='FIRST')
                created=request('/api/v1/libraries','POST',payload); request(f'/api/v1/libraries/{created["id"]}/scan','POST')
                deadline=time.monotonic()+120
                while True:
                    books=request('/api/v1/books/list','POST',{})['content']
                    if len(books)==3 and all(b['media']['status']=='READY' for b in books): break
                    if time.monotonic()>deadline: raise TimeoutError('Synthetic CBZ/EPUB/PDF analysis failed')
                    time.sleep(1)
                environment=os.environ.copy(); environment.update(KMREADER_TEST_URL=f'http://127.0.0.1:{port}',KMREADER_TEST_EMAIL=email,KMREADER_TEST_PASSWORD=password)
                print('Komga ready with three analyzed synthetic books. Running the application client tests.',flush=True)
                result=subprocess.run(['flutter','test','test/live_komga_test.dart','--reporter','expanded'],env=environment)
                if result.returncode: raise RuntimeError(f'Client integration tests exited {result.returncode}')
            except Exception:
                print((root/'server.log').read_text()[-4000:]); raise
            finally:
                server.terminate()
                try: server.wait(timeout=15)
                except subprocess.TimeoutExpired: server.kill(); server.wait()


if __name__=='__main__': main()
