import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';

void main() {
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
