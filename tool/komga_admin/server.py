"""KMReader upload companion. Python 3.11+, no external dependencies."""
import argparse
import ctypes
import errno
import hashlib
from heapq import nsmallest
import http.server
import json
import logging
import os
from pathlib import Path
import re
import socket
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid


class Failure(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def component(value):
    if not isinstance(value, str) or not value.strip() or value.startswith('.') or any(c in value for c in '/\\\x00') or any(ord(c) < 32 for c in value) or len(value.encode()) > 240:
        raise Failure(400, 'Invalid folder or filename')
    return value


def folder_components(value):
    if not isinstance(value, str) or len(value.encode()) > 1024:
        raise Failure(400, 'Invalid folder or filename')
    parts = value.split('/')
    if len(parts) > 16:
        raise Failure(400, 'Invalid folder or filename')
    return [component(part) for part in parts]


def publish(directory, source, destination):
    """Atomic Linux rename with NOREPLACE; hard-link fallback never overwrites."""
    libc = ctypes.CDLL(None, use_errno=True)
    rename = getattr(libc, 'renameat2', None)
    if rename is not None:
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(directory, os.fsencode(source), directory, os.fsencode(destination), 1) == 0:
            return
        code = ctypes.get_errno()
        if code not in (errno.ENOSYS, errno.EINVAL, errno.EOPNOTSUPP):
            raise OSError(code, 'Atomic publication failed')
    os.link(source, destination, src_dir_fd=directory, dst_dir_fd=directory, follow_symlinks=False)
    os.unlink(source, dir_fd=directory)


class Application:
    def __init__(self, config):
        self.base = config['komga_url'].rstrip('/')
        parsed = urllib.parse.urlsplit(self.base)
        if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError('Use a Komga URL without credentials, query or fragment')
        self.libraries = config.get('libraries', {})
        self.enrollment_roots = [
            (Path(row['komga_root']), Path(row['path']).resolve(strict=True))
            for row in config.get('enrollment_roots', [])
        ]
        if any(not root.is_absolute() or '..' in root.parts
               for root, _ in self.enrollment_roots):
            raise ValueError('Enrollment roots must be absolute Komga paths')
        self.state = Path(config['state_directory'])
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.maximum = int(config.get('max_upload_bytes', 2 * 1024**3))
        self.writer = threading.Lock()
        self.enrollments = self.state / 'registered-libraries.json'
        self.enrolled = json.loads(self.enrollments.read_text()) if self.enrollments.exists() else {}
        self.enrollment_lock = threading.Lock()
        self.opener = urllib.request.build_opener(NoRedirect(), urllib.request.ProxyHandler({}))

    def request(self, auth, path, method='GET', body=None):
        headers = dict(auth)
        if body is not None:
            body = json.dumps(body).encode()
            headers['Content-Type'] = 'application/json'
        try:
            with self.opener.open(urllib.request.Request(self.base + path, body, headers, method=method), timeout=20) as reply:
                data = reply.read(2 * 1024**2 + 1)
                if len(data) > 2 * 1024**2:
                    raise Failure(502, 'Unexpected Komga response')
                return json.loads(data) if data else None
        except urllib.error.HTTPError as error:
            raise Failure(error.code if error.code in (401, 403, 404) else 502, 'Komga rejected the request') from None
        except (OSError, ValueError):
            raise Failure(502, 'Komga is unavailable') from None

    def authorize(self, headers):
        auth = {key: headers[key] for key in ('Authorization', 'X-API-Key') if headers.get(key)}
        if len(auth) != 1:
            raise Failure(401, 'Komga authentication required')
        user = self.request(auth, '/api/v2/users/me')
        if 'ADMIN' not in user.get('roles', []) or not user.get('id'):
            raise Failure(403, 'Komga administrator required')
        # Confirm the effective token's privileges, not only the user's roles.
        self.request(auth, '/api/v1/filesystem', 'POST', {'path': '', 'showFiles': False})
        return auth, user['id']

    def komga_library(self, auth, identifier):
        return self.request(auth, '/api/v1/libraries/' + urllib.parse.quote(identifier, safe=''))

    def _enrollment_path(self, komga_root):
        remote = Path(komga_root)
        if not remote.is_absolute() or '..' in remote.parts:
            raise Failure(403, 'Library root is outside the allowed upload locations')
        for prefix, base in sorted(self.enrollment_roots, key=lambda pair: -len(pair[0].parts)):
            if remote.is_relative_to(prefix):
                relative = remote.relative_to(prefix)
                parts = [component(part) for part in relative.parts]
                return base, parts
        raise Failure(403, 'Library root is outside the allowed upload locations')

    def register_library(self, auth, identifier):
        dto = self.komga_library(auth, identifier)
        if identifier in self.libraries:
            self.library(auth, identifier)
            return {'id': identifier, 'name': dto['name']}
        base, parts = self._enrollment_path(dto['root'])
        fd = self._open_directory(base, parts)
        try:
            if not os.access('.', os.W_OK | os.X_OK, dir_fd=fd, effective_ids=True):
                raise Failure(403, 'The companion cannot write to this library')
        finally:
            os.close(fd)
        with self.enrollment_lock:
            enrolled = {**self.enrolled, identifier: dto['root']}
            self._save_json(self.enrollments, enrolled)
            self.enrolled = enrolled
        return {'id': identifier, 'name': dto['name']}

    def library(self, auth, identifier):
        mapping = self.libraries.get(identifier)
        enrolled = self.enrolled.get(identifier)
        if mapping is None and enrolled is None:
            raise Failure(403, 'Library is not enabled for uploads')
        dto = self.komga_library(auth, identifier)
        expected = enrolled if mapping is None else mapping.get('komga_root', mapping['path'])
        if os.path.normpath(dto['root']) != os.path.normpath(expected):
            raise Failure(409, 'Configured library root does not match Komga')
        if mapping is None:
            root, parts = self._enrollment_path(expected)
        else:
            root, parts = Path(mapping['path']).resolve(strict=True), []
        return dto, root, parts

    @staticmethod
    def _open_directory(root, parts, create=False, root_fd=None):
        current = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
        try:
            for name in parts:
                if create:
                    try:
                        os.mkdir(name, 0o2770, dir_fd=current)
                    except FileExistsError:
                        pass
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
                os.close(current)
                current = child
            return current
        except Exception:
            os.close(current)
            raise

    def directory(self, auth, record, create=False):
        dto, root, parts = self.library(auth, record['library'])
        current = self._open_directory(root, parts)
        try:
            path = record['folder']
            if path != '':
                child = self._open_directory('.', folder_components(path), create, root_fd=current)
                os.close(current)
                current = child
            return dto, current
        except Exception:
            os.close(current)
            raise

    def folders(self, auth, identifier, parent, after):
        _, fd = self.directory(auth, {'library': identifier, 'folder': parent})
        try:
            # Keep file names, symlinks and hidden directories out of the
            # browser. Only the bounded set of names for this page is returned.
            with os.scandir(fd) as entries:
                names = nsmallest(201, (entry.name for entry in entries
                    if entry.name > after and not entry.name.startswith('.')
                    and entry.is_dir(follow_symlinks=False)))
            return {'folders': names[:200], 'next': names[199] if len(names) > 200 else None}
        finally:
            os.close(fd)

    def create_folder(self, auth, identifier, parent, name):
        name = component(name)
        relative = f'{parent}/{name}' if parent else name
        folder_components(relative)
        _, fd = self.directory(auth, {'library': identifier, 'folder': parent})
        try:
            os.mkdir(name, 0o2770, dir_fd=fd)
            os.fsync(fd)
        finally:
            os.close(fd)
        return {'folder': relative}

    def request_batch_scan(self, auth, owner, identifier, ids):
        if not isinstance(ids, list) or not 1 <= len(ids) <= 100 or any(
            not isinstance(value, str) or str(uuid.UUID(value)) != value for value in ids
        ):
            raise Failure(400, 'Invalid upload IDs')
        if not self.writer.acquire(blocking=False):
            raise Failure(409, 'Upload is still active')
        try:
            self.library(auth, identifier)
            records = {}
            for upload_id in ids:
                record = self.receipt(upload_id, owner)
                if record['status'] != 'uploaded' or record['library'] != identifier:
                    raise Failure(409, 'Uploads are not ready for the requested library')
                records[upload_id] = record
            if not all(record['scan_requested'] for record in records.values()):
                self.request(auth, '/api/v1/libraries/' + urllib.parse.quote(identifier, safe='') + '/scan', 'POST')
                for upload_id, record in records.items():
                    record['scan_requested'] = True
                    self.save(upload_id, record)
            return {'scan_requested': True}
        finally:
            self.writer.release()

    def save(self, identifier, record):
        self._save_json(self.state / (identifier + '.json'), record)

    def _save_json(self, target, record):
        temporary = target.with_suffix('.json.tmp')
        with temporary.open('w', encoding='utf-8') as output:
            json.dump(record, output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, target)
        fd = os.open(self.state, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def receipt(self, identifier, owner):
        try:
            record = json.loads((self.state / (identifier + '.json')).read_text())
        except FileNotFoundError:
            raise Failure(404, 'Upload not found') from None
        if record['owner'] != owner:
            raise Failure(403, 'Upload belongs to another account')
        return record

    def scan(self, auth, identifier, record):
        try:
            self.request(auth, '/api/v1/libraries/' + urllib.parse.quote(record['library'], safe='') + '/scan', 'POST')
            record['scan_requested'] = True
        except Failure:
            record['scan_requested'] = False
        self.save(identifier, record)
        return record

    def upload(self, identifier, owner, auth, fields, headers, stream):
        if headers.get('Transfer-Encoding') or len(headers.get_all('Content-Length', [])) != 1:
            raise Failure(411, 'A fixed Content-Length is required')
        try:
            size = int(headers['Content-Length'])
        except (ValueError, TypeError):
            raise Failure(400, 'Invalid upload size') from None
        if not 0 < size <= self.maximum:
            raise Failure(413, 'File exceeds the configured upload limit')
        expected = headers.get('X-Content-SHA256', '')
        if not re.fullmatch('[a-f0-9]{64}', expected):
            raise Failure(400, 'SHA256 is required')
        record = dict(owner=owner, library=fields.get('library'), folder='/'.join(folder_components(fields.get('folder'))), filename=component(fields.get('filename')), size=size, sha256=expected, status='receiving', scan_requested=False)
        deferred = fields.get('defer_scan') == '1'
        extension = Path(record['filename']).suffix.lower()
        if extension not in ('.cbz', '.cbr', '.epub', '.pdf'):
            raise Failure(415, 'Use CBZ, CBR, EPUB or PDF')
        if not self.writer.acquire(blocking=False):
            raise Failure(409, 'Another upload is active; check its status before retrying')
        folder_fd = None
        part = '.' + identifier + '.part'
        try:
            try:
                old = self.receipt(identifier, owner)
            except Failure as error:
                if error.status != 404:
                    raise
                old = None
            if old:
                if any(old[k] != record[k] for k in ('owner', 'library', 'folder', 'filename', 'size', 'sha256')):
                    raise Failure(409, 'Upload identity cannot be reused for a different file')
                if old['status'] == 'uploaded':
                    return old
            dto, folder_fd = self.directory(auth, record, create=True)
            flag = 'scanPdf' if extension == '.pdf' else 'scanEpub' if extension == '.epub' else 'scanCbx'
            if not dto.get(flag):
                raise Failure(409, 'Enable this format in the Komga library settings')
            try:
                destination = os.stat(record['filename'], dir_fd=folder_fd, follow_symlinks=False)
            except FileNotFoundError:
                destination = None
            if destination is not None:
                # Recover only our own atomically published inode after a crash.
                try:
                    staged = os.stat(part, dir_fd=folder_fd, follow_symlinks=False)
                except FileNotFoundError:
                    staged = None
                owned_inode = old and (old.get('staged_device'), old.get('staged_inode')) == (destination.st_dev, destination.st_ino)
                owned_link = staged and (staged.st_dev, staged.st_ino) == (destination.st_dev, destination.st_ino)
                if old and old['status'] == 'staged' and (owned_inode or owned_link):
                    old['status'] = 'uploaded'
                    self.save(identifier, old)
                    if staged:
                        os.unlink(part, dir_fd=folder_fd)
                    return old if deferred else self.scan(auth, identifier, old)
                raise Failure(409, 'A file with this name already exists; it was not overwritten')
            try:
                os.unlink(part, dir_fd=folder_fd)
            except FileNotFoundError:
                pass
            self.save(identifier, record)
            fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=folder_fd)
            try:
                digest = hashlib.sha256()
                remaining = size
                beginning = b''
                with os.fdopen(fd, 'wb') as output:
                    while remaining:
                        block = stream.read(min(65536, remaining))
                        if not block:
                            raise Failure(400, 'Upload interrupted; no book was published')
                        if not beginning:
                            beginning = block[:1024]
                        digest.update(block)
                        output.write(block)
                        remaining -= len(block)
                    if digest.hexdigest() != expected:
                        raise Failure(422, 'Upload checksum mismatch')
                    magic = b'%PDF-' in beginning if extension == '.pdf' else beginning.startswith(b'Rar!\x1a\x07') if extension == '.cbr' else beginning.startswith(b'PK\x03\x04')
                    if not magic:
                        raise Failure(415, 'File content does not match its extension')
                    output.flush()
                    os.fchmod(output.fileno(), 0o640)
                    os.fsync(output.fileno())
                # Recheck effective authorization and the configured root after
                # a long transfer, before making any book visible to Komga.
                _, current_owner = self.authorize(auth)
                if current_owner != owner:
                    raise Failure(403, 'Komga administrator required')
                self.library(auth, record['library'])
                staged = os.stat(part, dir_fd=folder_fd, follow_symlinks=False)
                record.update(status='staged', staged_device=staged.st_dev, staged_inode=staged.st_ino)
                self.save(identifier, record)
                publish(folder_fd, part, record['filename'])
                os.fsync(folder_fd)
                record['status'] = 'uploaded'
                self.save(identifier, record)
                try:
                    os.unlink(part, dir_fd=folder_fd)
                except FileNotFoundError:
                    pass
            except Exception:
                # Keep a verified staged inode for crash recovery after publication.
                if record['status'] == 'receiving':
                    record['status'] = 'interrupted'
                    self.save(identifier, record)
                    try:
                        os.unlink(part, dir_fd=folder_fd)
                    except FileNotFoundError:
                        pass
                raise
            return record if deferred else self.scan(auth, identifier, record)
        finally:
            if folder_fd is not None:
                os.close(folder_fd)
            self.writer.release()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # Never log credentials, book names or upload queries.

    def reply(self, status, value):
        if isinstance(value, dict) and 'status' in value:
            value = {key: item for key, item in value.items() if key not in ('owner', 'staged_device', 'staged_inode')}
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def json_body(self):
        lengths = self.headers.get_all('Content-Length', [])
        if len(lengths) != 1 or self.headers.get('Transfer-Encoding'):
            raise Failure(411, 'A fixed Content-Length is required')
        count = int(lengths[0])
        if not 0 < count <= 16384:
            raise Failure(400, 'Invalid request size')
        value = json.loads(self.rfile.read(count))
        if not isinstance(value, dict):
            raise Failure(400, 'Expected an object')
        return value

    def dispatch(self):
        try:
            self.connection.settimeout(30)
            auth, owner = self.server.app.authorize(self.headers)
            url = urllib.parse.urlsplit(self.path)
            if self.command == 'GET' and url.path == '/v1/libraries':
                libraries = []
                for identifier in self.server.app.libraries.keys() | self.server.app.enrolled.keys():
                    try:
                        dto, _, _ = self.server.app.library(auth, identifier)
                    except Failure as error:
                        if error.status in (404, 409):
                            continue
                        raise
                    libraries.append({k: dto[k] for k in ('id', 'name')})
                libraries.sort(key=lambda library: (library['name'].casefold(), library['id']))
                self.reply(200, {
                    'libraries': libraries, 'max_upload_bytes': self.server.app.maximum,
                    'capabilities': {'folders': True, 'batch_scan': True,
                                     'enrollment': bool(self.server.app.enrollment_roots)},
                })
                return
            library_route = re.fullmatch('/v1/libraries/([^/]+)/(folders|enroll|scan)', url.path)
            if library_route:
                library = urllib.parse.unquote(library_route[1])
                if not library or len(library) > 120 or any(c in library for c in '/\\'):
                    raise Failure(400, 'Invalid library')
                if library_route[2] == 'folders' and self.command == 'GET':
                    query = urllib.parse.parse_qs(url.query, strict_parsing=True)
                    parent = query.get('parent', [''])[0]
                    after = query.get('after', [''])[0]
                    self.reply(200, self.server.app.folders(auth, library, parent, after))
                elif library_route[2] == 'folders' and self.command == 'POST':
                    body = self.json_body()
                    self.reply(201, self.server.app.create_folder(auth, library, body.get('parent'), body.get('name')))
                elif library_route[2] == 'enroll' and self.command == 'POST':
                    self.reply(200, self.server.app.register_library(auth, library))
                elif library_route[2] == 'scan' and self.command == 'POST':
                    self.reply(200, self.server.app.request_batch_scan(auth, owner, library, self.json_body().get('uploads')))
                else:
                    raise Failure(405, 'Method not allowed')
                return
            match = re.fullmatch('/v1/uploads/([a-f0-9-]{36})(/scan)?', url.path)
            if not match:
                raise Failure(404, 'Unknown endpoint')
            identifier = str(uuid.UUID(match[1]))
            if identifier != match[1]:
                raise Failure(400, 'Invalid upload ID')
            if self.command == 'GET' and not match[2]:
                self.reply(200, self.server.app.receipt(identifier, owner))
            elif self.command == 'POST' and match[2]:
                if not self.server.app.writer.acquire(blocking=False):
                    raise Failure(409, 'Upload is still active')
                try:
                    record = self.server.app.receipt(identifier, owner)
                    if record['status'] != 'uploaded':
                        raise Failure(409, 'Check or retry the interrupted upload first')
                    self.reply(200, self.server.app.scan(auth, identifier, record))
                finally:
                    self.server.app.writer.release()
            elif self.command == 'PUT' and not match[2]:
                fields = urllib.parse.parse_qs(url.query, strict_parsing=True)
                required = {'library', 'folder', 'filename'}
                if not required <= set(fields) <= required | {'defer_scan'} or any(len(v) != 1 for v in fields.values()) or fields.get('defer_scan', ['1']) != ['1']:
                    raise Failure(400, 'Invalid upload destination')
                record = self.server.app.upload(identifier, owner, auth, {k: v[0] for k, v in fields.items()}, self.headers, self.rfile)
                self.reply(200, record)
            else:
                raise Failure(405, 'Method not allowed')
        except Failure as error:
            self.reply(error.status, {'error': error.message})
        except (ValueError, FileNotFoundError):
            self.reply(400, {'error': 'Invalid destination or request'})
        except FileExistsError:
            self.reply(409, {'error': 'Destination already exists; no file was overwritten'})
        except (OSError, socket.timeout) as error:
            logging.warning('Storage/connection failure: errno=%s', getattr(error, 'errno', None))
            try:
                self.reply(503, {'error': 'Storage or connection unavailable; check upload status before retrying'})
            except OSError:
                pass

    do_GET = do_PUT = do_POST = dispatch


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, address, app):
        super().__init__(address, Handler)
        self.app = app
        self.slots = threading.BoundedSemaphore(8)

    def handle_error(self, request, address):
        logging.error('Request handler interrupted')

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--port', type=int, default=8788)
    args = parser.parse_args()
    app = Application(json.loads(args.config.read_text()))
    with Server(('127.0.0.1', args.port), app) as server:
        server.serve_forever()


if __name__ == '__main__':
    main()
