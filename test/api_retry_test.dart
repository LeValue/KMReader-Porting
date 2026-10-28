import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';

void main() {
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
