"""Exercise uploads and native admin operations on disposable real Komga 1.30.1."""
import argparse
import base64
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zipfile

from tool.komga_admin.server import Application, Server
from tool.komga_smoke import png


class Proxy(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def handle_request(self):
        path = self.path.removeprefix('/komga')
        upload = path.startswith('/kmreader-admin/')
        port = self.server.upload_port if upload else self.server.komga_port
        if upload:
            path = path.removeprefix('/kmreader-admin')
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=60)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ('host', 'connection')}
        connection.putrequest(self.command, path)
        for key, value in headers.items():
            connection.putheader(key, value)
        connection.endheaders()
        remaining = int(self.headers.get('Content-Length', 0))
        while remaining:
            block = self.rfile.read(min(65536, remaining))
            if not block:
                break
            connection.send(block); remaining -= len(block)
        response = connection.getresponse(); data = response.read()
        self.send_response(response.status)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Content-Type', response.getheader('Content-Type', 'application/json'))
        self.send_header('Connection', 'close'); self.end_headers(); self.wfile.write(data)
        connection.close(); self.close_connection = True
    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = handle_request


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--jar', type=Path, required=True); args = parser.parse_args()
    assert hashlib.file_digest(args.jar.open('rb'), 'sha256').hexdigest() == 'a443bc806800ccbecca84fa433bc8307230fc985984225fe00a85503077ed6d9', 'Expected Komga 1.30.1'
    with tempfile.TemporaryDirectory(prefix='komga-admin-live-') as temporary:
        root = Path(temporary); library = root/'library'; library.mkdir()
        fixture = root/'fixture.cbz'
        with zipfile.ZipFile(fixture, 'w') as archive:
            archive.writestr('001.png', png((255, 0, 0))); archive.writestr('002.png', png((0, 255, 0)))
        cover = root/'cover.png'; cover.write_bytes(png((0, 0, 255)))
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        auth = None
        def request(path, method='GET', body=None, extra=None):
            headers = dict(extra or {})
            if auth:
                headers['Authorization'] = auth
            if body is not None:
                body = json.dumps(body).encode(); headers['Content-Type'] = 'application/json'
            with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}'+path, body, headers, method=method), timeout=60) as reply:
                data = reply.read(); return json.loads(data) if data else None
        uploads = frontend = None
        with (root/'komga.log').open('w') as log:
            process = subprocess.Popen(['java', '-Xmx768m', '-XX:ActiveProcessorCount=2', '-jar', str(args.jar.resolve()), '--server.address=127.0.0.1', f'--server.port={port}', f'--komga.config-dir={root / "config"}'], stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic()+180
                while True:
                    if process.poll() is not None:
                        raise RuntimeError('Disposable Komga exited')
                    try:
                        request('/api/v1/claim'); break
                    except OSError:
                        if time.monotonic() > deadline:
                            raise TimeoutError('Disposable Komga startup')
                        time.sleep(1)
                email = 'admin@example.invalid'; password = secrets.token_urlsafe(24)
                request('/api/v1/claim', 'POST', extra={'X-Komga-Email': email, 'X-Komga-Password': password})
                auth = 'Basic '+base64.b64encode(f'{email}:{password}'.encode()).decode()
                payload = {k: False for k in ['analyzeDimensions','convertToCbz','emptyTrashAfterScan','hashFiles','hashKoreader','hashPages','importBarcodeIsbn','importComicInfoBook','importComicInfoCollection','importComicInfoReadList','importComicInfoSeries','importComicInfoSeriesAppendVolume','importEpubBook','importEpubSeries','importLocalArtwork','importMylarSeries','repairExtensions','scanCbx','scanEpub','scanForceModifiedTime','scanOnStartup','scanPdf']}
                payload.update(name='Synthetic uploads', root=str(library), scanCbx=True, scanEpub=True, scanPdf=True, analyzeDimensions=True, scanDirectoryExclusions=[], scanInterval='DISABLED', seriesCover='FIRST')
                created = request('/api/v1/libraries', 'POST', payload)
                uploads = Server(('127.0.0.1', 0), Application({'komga_url': f'http://127.0.0.1:{port}', 'state_directory': str(root/'journal'), 'libraries': {created['id']: {'path': str(library)}}}))
                frontend = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
                frontend.upload_port = uploads.server_port; frontend.komga_port = port
                for server in (uploads, frontend):
                    threading.Thread(target=server.serve_forever, daemon=True).start()
                environment = dict(os.environ, KMREADER_KOMGA_ADMIN_TEST='1', KMREADER_ADMIN_URL=f'http://127.0.0.1:{frontend.server_port}/komga', KMREADER_ADMIN_EMAIL=email, KMREADER_ADMIN_PASSWORD=password, KMREADER_ADMIN_LIBRARY=created['id'], KMREADER_ADMIN_ROOT=str(library), KMREADER_ADMIN_FIXTURE=str(fixture), KMREADER_ADMIN_COVER=str(cover))
                result = subprocess.run(['flutter', 'test', '--no-pub', 'test/live_komga_admin_test.dart', '--reporter', 'expanded'], env=environment)
                if result.returncode:
                    raise RuntimeError('Real Komga admin integration failed')
            except Exception:
                print((root/'komga.log').read_text()[-3000:]); raise
            finally:
                for server in (frontend, uploads):
                    if server:
                        server.shutdown(); server.server_close()
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()


if __name__ == '__main__':
    main()
