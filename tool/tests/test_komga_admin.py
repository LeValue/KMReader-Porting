import hashlib
import io
from email.message import Message
import http.server
import json
from pathlib import Path
import tempfile
import socket
import threading
import unittest
import urllib.error
import urllib.request
import uuid
import sys

from tool.komga_admin.server import Application, Server, Failure


class Upstream(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        token = self.headers.get('X-API-Key')
        if token not in ('admin', 'other', 'reader', 'restricted'):
            self.send_error(401); return
        if self.path == '/api/v2/users/me':
            value = {'id': token, 'roles': ['USER'] if token == 'reader' or self.server.revoked else ['ADMIN']}
        elif self.path == '/api/v1/libraries/lib':
            value = {'id': 'lib', 'name': 'Synthetic library', 'root': str(self.server.root), 'scanCbx': True, 'scanPdf': True, 'scanEpub': True}
        else:
            self.send_error(404); return
        body = json.dumps(value).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_POST(self):
        if self.headers.get('X-API-Key') not in ('admin', 'other'):
            self.send_error(403); return
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/api/v1/libraries/lib/scan':
            self.server.scans += 1
            self.send_response(503 if self.server.fail_scan else 202); self.end_headers()
        elif self.path == '/api/v1/filesystem':
            self.send_response(200); self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(b'{}')
        else:
            self.send_error(404)


@unittest.skipUnless(sys.platform.startswith('linux'), 'Debian/Linux companion filesystem semantics')
class UploadTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        library = self.root/'library'; library.mkdir()
        self.upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        self.upstream.root = library; self.upstream.scans = 0; self.upstream.fail_scan = False; self.upstream.revoked = False
        self.app = Application({'komga_url': f'http://127.0.0.1:{self.upstream.server_port}', 'state_directory': str(self.root/'state'), 'max_upload_bytes': 1024, 'libraries': {'lib': {'path': str(library)}}})
        self.server = Server(('127.0.0.1', 0), self.app)
        for server in (self.upstream, self.server):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        self.identifier = str(uuid.uuid4()); self.data = b'PK\x03\x04synthetic comic'

    def tearDown(self):
        for server in (self.server, self.upstream):
            server.shutdown(); server.server_close()
        self.temp.cleanup()

    def request(self, path, method='GET', data=None, token='admin', extra=None):
        headers = {'X-API-Key': token, **(extra or {})}
        try:
            with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{self.server.server_port}{path}', data, headers, method=method), timeout=5) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def upload(self, filename='New.cbz', folder='Series', data=None, digest=None, token='admin'):
        data = self.data if data is None else data
        query = urllib.parse.urlencode({'library': 'lib', 'folder': folder, 'filename': filename})
        return self.request(f'/v1/uploads/{self.identifier}?{query}', 'PUT', data, token=token, extra={'X-Content-SHA256': digest or hashlib.sha256(data).hexdigest()})

    def test_upload_scan_idempotency_and_owner(self):
        status, receipt = self.upload()
        self.assertEqual(status, 200); self.assertTrue(receipt['scan_requested'])
        self.assertEqual((self.upstream.root/'Series/New.cbz').read_bytes(), self.data)
        self.assertEqual(self.upload()[0], 200); self.assertEqual(self.upstream.scans, 1)
        self.assertEqual(self.request('/v1/uploads/'+self.identifier, token='other')[0], 403)
        self.assertEqual(self.request('/v1/uploads/'+self.identifier)[1]['status'], 'uploaded')
        self.identifier = str(uuid.uuid4())
        self.assertEqual(self.upload()[0], 409)
        self.assertEqual((self.upstream.root/'Series/New.cbz').read_bytes(), self.data)

    def test_permissions_and_token_effective_role(self):
        for token, expected in [('invalid', 401), ('reader', 403), ('restricted', 403)]:
            self.assertEqual(self.upload(token=token)[0], expected)
        self.assertEqual(list(self.upstream.root.iterdir()), [])

    def test_paths_symlinks_digest_and_size(self):
        for folder, filename in [('../escape', 'x.cbz'), ('Series', '../x.cbz'), ('Series', '/x.cbz'), ('Series', '.hidden.cbz')]:
            self.assertEqual(self.upload(folder=folder, filename=filename)[0], 400)
        outside = self.root/'outside'; outside.mkdir(); (self.upstream.root/'Linked').symlink_to(outside)
        self.assertEqual(self.upload(folder='Linked')[0], 503)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertEqual(self.upload(digest='0'*64)[0], 422)
        self.assertFalse((self.upstream.root/'Series/New.cbz').exists())
        self.identifier = str(uuid.uuid4())
        self.assertEqual(self.upload(data=b'x'*1025)[0], 413)
        self.assertEqual(self.upload(data=b'not a zip')[0], 415)
        self.identifier = str(uuid.uuid4())
        self.assertEqual(self.upload()[0], 200)

    def test_scan_failure_retains_file_and_can_rescan(self):
        self.upstream.fail_scan = True
        status, receipt = self.upload(); self.assertEqual(status, 200); self.assertFalse(receipt['scan_requested'])
        self.upstream.fail_scan = False
        status, receipt = self.request('/v1/uploads/'+self.identifier+'/scan', 'POST', b'')
        self.assertEqual(status, 200); self.assertTrue(receipt['scan_requested'])
        self.assertEqual((self.upstream.root/'Series/New.cbz').read_bytes(), self.data)

    def test_recovery_after_published_inode_before_journal_commit(self):
        self.upload()
        record = self.app.receipt(self.identifier, 'admin')
        target = self.upstream.root/'Series/New.cbz'; part = target.parent/('.'+self.identifier+'.part')
        part.hardlink_to(target); record['status'] = 'staged'; self.app.save(self.identifier, record)
        self.assertEqual(self.upload()[0], 200)
        self.assertFalse(part.exists()); self.assertEqual(target.read_bytes(), self.data)

    def test_interrupted_body_never_publishes_and_same_operation_can_retry(self):
        query = urllib.parse.urlencode({'library': 'lib', 'folder': 'Series', 'filename': 'New.cbz'})
        headers = (f'PUT /v1/uploads/{self.identifier}?{query} HTTP/1.0\r\n'
                   f'X-API-Key: admin\r\nContent-Length: {len(self.data)}\r\n'
                   f'X-Content-SHA256: {hashlib.sha256(self.data).hexdigest()}\r\n\r\n').encode()
        with socket.create_connection(self.server.server_address, timeout=5) as connection:
            connection.sendall(headers+self.data[:5]); connection.shutdown(socket.SHUT_WR)
            self.assertIn(b'400', connection.recv(4096).split(b'\r\n')[0])
        self.assertFalse((self.upstream.root/'Series/New.cbz').exists())
        self.assertEqual(list((self.upstream.root/'Series').glob('*.part')), [])
        self.assertEqual(self.upload()[0], 200)

    def test_role_revoked_during_transfer_cannot_publish(self):
        auth, owner = self.app.authorize({'X-API-Key': 'admin'})
        upstream = self.upstream
        class RevokingStream(io.BytesIO):
            def read(self, count=-1):
                data = super().read(count)
                upstream.revoked = True
                return data
        headers = Message(); headers['Content-Length'] = str(len(self.data))
        headers['X-Content-SHA256'] = hashlib.sha256(self.data).hexdigest()
        with self.assertRaises(Failure) as result:
            self.app.upload(self.identifier, owner, auth, {'library': 'lib', 'folder': 'Series', 'filename': 'New.cbz'}, headers, RevokingStream(self.data))
        self.assertEqual(result.exception.status, 403)
        self.assertFalse((self.upstream.root/'Series/New.cbz').exists())
        self.assertEqual(list((self.upstream.root/'Series').glob('*.part')), [])

    def test_nested_series_and_symlink_in_intermediate_directory(self):
        self.assertEqual(self.upload(folder='Publisher/Series')[0], 200)
        self.assertEqual((self.upstream.root/'Publisher/Series/New.cbz').read_bytes(), self.data)
        outside = self.root/'external'; outside.mkdir()
        (self.upstream.root/'Publisher/Linked').symlink_to(outside)
        self.identifier = str(uuid.uuid4())
        self.assertEqual(self.upload(folder='Publisher/Linked/Subseries')[0], 503)
        self.assertEqual(list(outside.iterdir()), [])

    def test_library_root_mismatch(self):
        self.app.libraries['lib']['komga_root'] = '/wrong'
        self.assertEqual(self.upload()[0], 409)
        self.assertEqual(list(self.upstream.root.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
