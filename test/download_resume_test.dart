import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  setUp(
    () => directory = Directory.systemTemp.createTempSync('download-resume-'),
  );
  tearDown(() => directory.deleteSync(recursive: true));
  KomgaApi apiFor(http.Client client) => KomgaApi(
    Uri.parse('https://example.invalid'),
    authentication: Authentication.apiKey,
    credential: 'synthetic',
    client: client,
  );
  Future<File> partial({String validator = '"v1"'}) async {
    final target = File('${directory.path}/book');
    await File('${target.path}.part').writeAsBytes([1, 2, 3]);
    await File('${target.path}.part.json').writeAsString(
      jsonEncode({
        'url': 'https://example.invalid/file',
        'validator': validator,
      }),
    );
    return target;
  }

  test(
    'resumes a validated partial transfer and commits only complete bytes',
    () async {
      final target = await partial();
      final api = apiFor(
        MockClient((request) async {
          expect(request.headers['Range'], 'bytes=3-');
          expect(request.headers['If-Range'], '"v1"');
          return http.Response.bytes(
            [4, 5],
            206,
            headers: {'content-range': 'bytes 3-4/5', 'etag': '"v1"'},
          );
        }),
      );
      try {
        await api.download('/file', target);
        expect(await target.readAsBytes(), [1, 2, 3, 4, 5]);
        expect(await File('${target.path}.part.json').exists(), isFalse);
      } finally {
        api.close();
      }
    },
  );
  test('changed validators and ignored ranges replace partial data', () async {
    final target = await partial();
    final api = apiFor(
      MockClient(
        (request) async =>
            http.Response.bytes([7, 8], 200, headers: {'etag': '"v2"'}),
      ),
    );
    try {
      await api.download('/file', target);
      expect(await target.readAsBytes(), [7, 8]);
    } finally {
      api.close();
    }
  });
  test('invalid range never commits a corrupted download', () async {
    final target = await partial();
    final api = apiFor(
      MockClient(
        (request) async => http.Response.bytes(
          [4, 5],
          206,
          headers: {'content-range': 'bytes 2-3/5', 'etag': '"v1"'},
        ),
      ),
    );
    try {
      await expectLater(
        api.download('/file', target),
        throwsA(isA<ApiFailure>()),
      );
      expect(await target.exists(), isFalse);
      expect(await File('${target.path}.part').exists(), isFalse);
    } finally {
      api.close();
    }
  });
  test(
    'interrupted stream leaves resumable bytes without publishing a target',
    () async {
      final target = File('${directory.path}/book');
      final api = apiFor(
        MockClient.streaming(
          (request, _) async => http.StreamedResponse(
            Stream<List<int>>.fromIterable([
              [1, 2],
              [3, 4],
            ]).asyncMap((bytes) {
              if (bytes.first == 3) {
                throw const SocketException('test interruption');
              }
              return bytes;
            }),
            200,
            headers: {'etag': '"v1"'},
            contentLength: 4,
          ),
        ),
      );
      try {
        await expectLater(
          api.download('/file', target),
          throwsA(isA<SocketException>()),
        );
        expect(await target.exists(), isFalse);
        expect(await File('${target.path}.part').readAsBytes(), [1, 2]);
      } finally {
        api.close();
      }
    },
  );
  test('download queue bounds active transfers, deduplicates work and cancels queued items', () async {
    final gates = <String, StreamController<List<int>>>{};
    final store = LocalStore(sqlite3.openInMemory());
    final api = apiFor(
      MockClient.streaming((request, _) async {
        if (request.url.path.endsWith('/thumbnail')) {
          return http.StreamedResponse(Stream.value([1]), 200);
        }
        final id = request.url.path.split('/')[4];
        final gate = StreamController<List<int>>();
        gates[id] = gate;
        return http.StreamedResponse(gate.stream, 200, contentLength: 1);
      }),
    );
    final repository = Repository(
      profile: const ServerProfile(
        id: 's',
        name: 'Test',
        url: 'https://example.invalid',
        email: 'test@example.invalid',
        authentication: Authentication.apiKey,
      ),
      api: api,
      store: store,
      directory: directory,
    );
    Book book(String id) => Book({
      'id': id,
      'media': {'mediaType': 'application/pdf'},
    });
    try {
      final first = repository.download(book('a')),
          second = repository.download(book('b'));
      expect(identical(first, repository.download(book('a'))), isTrue);
      final third = repository.download(book('c'));
      final cancelled = expectLater(third, throwsA(isA<ApiFailure>()));
      repository.cancelDownload('c');
      await cancelled;
      for (var i = 0; i < 50 && gates.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(gates.keys.toSet(), {'a', 'b'});
      expect(repository.downloading.length, 2);
      expect(store.download('s', 'c')!['status'], 'cancelled');
      for (final gate in gates.values) {
        gate.add([1]);
        await gate.close();
      }
      await Future.wait([first, second]);
      expect(store.download('s', 'a')!['status'], 'ready');
      expect(await repository.bookFile(book('a')).readAsBytes(), [1]);
    } finally {
      repository.dispose();
      store.close();
    }
  });
  test('concurrent consumers share the same file transfer', () async {
    final gate = Completer<void>();
    var requests = 0;
    final api = apiFor(
      MockClient((request) async {
        requests++;
        await gate.future;
        return http.Response.bytes([1, 2, 3], 200, headers: {'etag': '"v1"'});
      }),
    );
    final target = File('${directory.path}/shared');
    try {
      final first = api.download('/file', target),
          second = api.download('/file', target);
      expect(identical(first, second), isTrue);
      gate.complete();
      await Future.wait([first, second]);
      expect(requests, 1);
      expect(await target.readAsBytes(), [1, 2, 3]);
    } finally {
      api.close();
    }
  });
  test(
    'native HTTP cancellation aborts an idle response before its timeout',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      server.listen((request) {
        request.response.bufferOutput = false;
        request.response.contentLength = 1024;
        request.response.headers.set('ETag', '"v1"');
        request.response.add([1]);
        unawaited(
          request.response
              .flush()
              .then<void>((_) {
                if (!started.isCompleted) {
                  started.complete();
                }
              })
              .catchError((Object _) {}),
        );
      });
      final api = KomgaApi(
        Uri.parse('http://127.0.0.1:${server.port}'),
        authentication: Authentication.apiKey,
        credential: 'synthetic',
      );
      final abort = Completer<void>();
      try {
        final transfer = api.download(
          '/file',
          File('${directory.path}/abort'),
          abortTrigger: abort.future,
        );
        final cancelled = expectLater(
          transfer,
          throwsA(
            isA<ApiFailure>().having(
              (e) => e.message,
              'message',
              'Download cancelled.',
            ),
          ),
        );
        await started.future.timeout(const Duration(seconds: 10));
        abort.complete();
        await cancelled.timeout(const Duration(seconds: 5));
        expect(await File('${directory.path}/abort').exists(), isFalse);
      } finally {
        api.close();
        await server.close(force: true);
      }
    },
  );
}
