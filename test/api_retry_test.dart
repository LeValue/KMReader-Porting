import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/network_preferences.dart';

void main() {
  test('body timeout closes a real loopback HTTP socket', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peers = <Socket>[];
    final disconnected = Completer<void>();
    final subscription = server.listen((socket) {
      peers.add(socket);
      var sent = false;
      socket.listen(
        (_) {
          if (sent) return;
          sent = true;
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Length: 9999\r\nContent-Type: application/json\r\n\r\n{',
          );
        },
        onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
        },
        onError: (Object _) {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
    });
    final api = KomgaApi(
      Uri.parse('http://127.0.0.1:${server.port}'),
      authentication: Authentication.apiKey,
      credential: '',
    );
    api.readNetworkPreferences = () =>
        const NetworkPreferences(request: 1, retries: 0);
    try {
      await expectLater(api.request('/slow'), throwsA(isA<ApiFailure>()));
      await disconnected.future.timeout(const Duration(seconds: 5));
    } finally {
      api.close();
      for (final peer in peers) {
        peer.destroy();
      }
      await subscription.cancel();
      await server.close();
    }
  });

  for (final mode in ['json-read', 'json-write', 'media']) {
    test(
      'a stalled $mode body closes its underlying request on timeout',
      () async {
        var calls = 0;
        final aborted = Completer<void>();
        final api = KomgaApi(
          Uri.parse('https://example.invalid'),
          authentication: Authentication.apiKey,
          credential: '',
          client: MockClient.streaming((request, _) async {
            calls++;
            final body = StreamController<List<int>>();
            unawaited(
              (request as http.Abortable).abortTrigger!.then((_) async {
                if (!aborted.isCompleted) aborted.complete();
                await body.close();
              }),
            );
            return http.StreamedResponse(body.stream, 200);
          }),
        );
        api.readNetworkPreferences = () =>
            const NetworkPreferences(request: 1, download: 1, retries: 0);
        try {
          if (mode == 'media') {
            await expectLater(
              api.mediaBytes('/image'),
              throwsA(isA<TimeoutException>()),
            );
          } else {
            await expectLater(
              api.request(
                '/slow',
                method: mode == 'json-write' ? 'POST' : 'GET',
              ),
              throwsA(isA<ApiFailure>()),
            );
          }
          await aborted.future.timeout(const Duration(seconds: 2));
          expect(calls, 1);
        } finally {
          api.close();
        }
      },
    );
  }
  test('authentication errors cancel an unfinished body without waiting or retrying', () async {
    var cancelled = false, calls = 0;
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: '',
      client: MockClient.streaming((_, _) async {
        calls++;
        final body = StreamController<List<int>>(
          onCancel: () => cancelled = true,
        );
        return http.StreamedResponse(body.stream, 401);
      }),
    );
    try {
      await expectLater(
        api.request('/private'),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 401)),
      );
      expect(cancelled, true);
      expect(calls, 1);
    } finally {
      api.close();
    }
  });

  for (final retries in [0, 1, 2]) {
    test('HEAD respects the configured limit of $retries retries', () async {
      var count = 0;
      final api = KomgaApi(
        Uri.parse('https://example.invalid'),
        authentication: Authentication.apiKey,
        credential: '',
        client: MockClient((request) async {
          expect(request.method, 'HEAD');
          count++;
          throw http.ClientException('Connection closed before headers');
        }),
      );
      api.readNetworkPreferences = () => NetworkPreferences(retries: retries);
      addTearDown(api.close);
      await expectLater(
        api.head('/file'),
        throwsA(isA<ApiFailure>().having((e) => e.offline, 'offline', true)),
      );
      expect(count, retries + 1);
    });
  }
  test('HEAD preserves conditional headers and accepts 304 after a response stream interruption', () async {
    var count = 0;
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: '',
      client: MockClient.streaming((request, body) async {
        expect(request.method, 'HEAD');
        expect(request.headers['If-None-Match'], '"v1"');
        count++;
        if (count == 1) {
          return http.StreamedResponse(
            Stream.error(http.ClientException('Interrupted response')),
            200,
          );
        }
        return http.StreamedResponse(
          const Stream.empty(),
          304,
          headers: {'etag': '"v1"'},
        );
      }),
    );
    api.readNetworkPreferences = () => const NetworkPreferences(retries: 1);
    addTearDown(api.close);
    final response = await api.head(
      '/file',
      extra: {'If-None-Match': '"v1"'},
      acceptedStatuses: {304},
    );
    expect(response.statusCode, 304);
    expect(response.headers['etag'], '"v1"');
    expect(count, 2);
  });
  test('HEAD never retries an authentication failure', () async {
    var count = 0;
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: '',
      client: MockClient((request) async {
        count++;
        return http.Response('', 401);
      }),
    );
    api.readNetworkPreferences = () => const NetworkPreferences(retries: 2);
    addTearDown(api.close);
    await expectLater(
      api.head('/file'),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 401)),
    );
    expect(count, 1);
  });
  test('original-file GET retries an interrupted connection but never retries authentication failure', () async {
    final directory = Directory.systemTemp.createTempSync('transfer-retry-');
    var calls = 0, unauthorized = false;
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: '',
      client: MockClient((request) async {
        calls++;
        if (unauthorized) return http.Response('', 401);
        if (calls == 1) {
          throw http.ClientException('Connection closed before headers');
        }
        return http.Response.bytes([1, 2, 3], 200, headers: {'etag': '"v1"'});
      }),
    );
    try {
      final target = File('${directory.path}/original');
      await api.download('/file', target);
      expect(await target.readAsBytes(), [1, 2, 3]);
      expect(calls, 2);
      calls = 0;
      unauthorized = true;
      await expectLater(
        api.download('/private', File('${directory.path}/private')),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 401)),
      );
      expect(calls, 1);
    } finally {
      api.close();
      directory.deleteSync(recursive: true);
    }
  });
  test('safe catalog reads recover from a stale connection; writes are never replayed', () async {
    var count = 0;
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: '',
      client: MockClient((request) async {
        count++;
        if (count == 1) {
          throw http.ClientException(
            'Connection closed before headers were received.',
          );
        }
        return http.Response('{"content":[]}', 200);
      }),
    );
    addTearDown(api.close);
    expect(await api.request('/api/v1/books/list', method: 'POST', body: {}), {
      'content': [],
    });
    expect(count, 2);
    count = 0;
    await expectLater(
      api.request(
        '/api/v1/books/book/metadata',
        method: 'PATCH',
        body: {'title': 'New'},
      ),
      throwsA(
        isA<ApiFailure>().having(
          (e) => e.path,
          'path',
          '/api/v1/books/book/metadata',
        ),
      ),
    );
    expect(count, 1);
  });
  test('authentication failures return immediately without retry', () async {
    var count = 0;
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: '',
      client: MockClient((request) async {
        count++;
        return http.Response('', 401);
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.request('/api/v1/books/list', method: 'POST'),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 401)),
    );
    expect(count, 1);
  });
}
