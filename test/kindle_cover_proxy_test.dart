import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/cover_proxy.dart';
import 'package:kmreader/core/models.dart';

void main() {
  final transport = HttpClient();
  tearDownAll(transport.close);
  test('cover worker capability serves only bounded ranges of selected signed resources', () async {
    var upstreamRequests = 0;
    final fixture = object(
      jsonDecode(
        File('test/support/kindle_protocol_fixture.json').readAsStringSync(),
      ),
    );
    final client = KindleClient(
      session: KindleSession({
        ...object(fixture['session']),
        'expires': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
      }),
      client: MockClient((request) async {
        upstreamRequests++;
        if (request.url.host == 'expired.cloudfront.net') {
          return http.Response('', 403);
        }
        expect(request.headers['range'], 'bytes=0-3');
        expect(request.headers['x-adp-token'], isNotEmpty);
        return http.Response.bytes(
          [1, 2, 3, 4],
          206,
          headers: {'content-range': 'bytes 0-3/4096', 'etag': '"test"'},
        );
      }),
    );
    final proxy = await KindleCoverProxy.open(client, {
      'resources': [
        {
          'type': 'KINDLE_MAIN_BASE',
          'optimalEndpoint': {
            'directUrl': 'https://expired.cloudfront.net/synthetic',
          },
          'endpoint': {
            'url': 'https://kindle-digital-delivery.amazon.com/synthetic',
          },
        },
      ],
    }, {});
    try {
      final request = await transport.getUrl(Uri.parse(proxy.urls.single));
      request.headers.set('Range', 'bytes=0-3');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(
        await response.fold<List<int>>([], (all, bytes) => all..addAll(bytes)),
        [1, 2, 3, 4],
      );
      for (final (url, range) in [
        (
          proxy.urls.single.replaceFirst(proxy.token, 'wrong-token'),
          'bytes=0-3',
        ),
        (proxy.urls.single, 'bytes=0-9000000'),
        (proxy.urls.single, 'bytes=4-0'),
      ]) {
        final request = await transport.getUrl(Uri.parse(url));
        request.headers.set('Range', range);
        final response = await request.close();
        expect(response.statusCode, 403);
        await response.drain<void>();
      }
      expect(upstreamRequests, 2);
      expect(proxy.urls.single, isNot(contains('amazon')));
    } finally {
      await proxy.close();
      client.close();
    }
  });
}
