import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/models.dart';

void main() {
  final fixture = object(
    jsonDecode(
      File('test/support/kindle_protocol_fixture.json').readAsStringSync(),
    ),
  );
  KindleSession session() => KindleSession({
    ...object(fixture['session']),
    'expires': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
  });
  test(
    'native ADP signature matches the Python device protocol byte for byte',
    () {
      final headers = kindleSigningHeaders(
        uri: Uri.parse(fixture['url']),
        session: session(),
        method: 'POST',
        body: utf8.encode(fixture['body']),
        timestamp: fixture['timestamp'],
      );
      expect(headers['x-adp-signature'], fixture['expected_signature']);
    },
  );
  test('PKCE callback preserves literal plus, decodes once and rejects duplicates', () {
    final attempt = KindleLoginAttempt(
      serial: 'SYNTHETIC',
      verifier: 'test-verifier',
      state: 'state',
    );
    expect(
      attempt.url.queryParameters['openid.assoc_handle'],
      'amzn_device_it',
    );
    expect(attempt.url.queryParameters['openid.oa2.response_type'], 'code');
    final callback = attempt.callback(
      Uri.parse(
        'https://www.amazon.it/ap/maplanding?openid.oa2.authorization_code=a+b/part%2Bvalue%252B&openid.oa2.state=state',
      ),
    )!;
    expect(callback['authorization_code'], 'a+b/part+value%2B');
    for (final url in [
      'https://www.amazon.it/ap/maplanding?openid.oa2.authorization_code=a&openid.oa2.authorization_code=b',
      'https://www.amazon.it/ap/maplanding?openid.oa2.authorization_code=a&state=other',
      'https://www.amazon.it/ap/maplanding?openid.oa2.authorization_code=a%20b',
    ]) {
      expect(
        () => attempt.callback(Uri.parse(url)),
        throwsA(isA<KindleFailure>()),
      );
    }
    expect(
      attempt.callback(
        Uri.parse(
          'https://www.amazon.it.evil.example/ap/maplanding?openid.oa2.authorization_code=code',
        ),
      ),
      isNull,
    );
  });
  test(
    'signed Amazon redirect never forwards ADP or other private headers to CDN',
    () async {
      var calls = 0;
      final client = KindleClient(
        session: session(),
        client: MockClient((request) async {
          calls++;
          if (calls == 1) {
            expect(request.headers['x-adp-token'], isNotEmpty);
            return http.Response(
              '',
              302,
              headers: {'location': 'https://synthetic.cloudfront.net/file'},
            );
          }
          expect(request.headers['x-adp-token'], isNull);
          expect(request.headers['x-adp-signature'], isNull);
          expect(request.headers['X-ADP-CorrelationId'], isNull);
          expect(request.headers['Range'], 'bytes=0-17');
          return http.Response('synthetic', 206);
        }),
      );
      try {
        final response = await client.request(
          Uri.parse('https://cde-ta-g7g.amazon.com/file'),
          headers: {'Range': 'bytes=0-17', 'X-ADP-CorrelationId': 'PRIVATE'},
        );
        await response.stream.drain<void>();
        expect(calls, 2);
      } finally {
        client.close();
      }
    },
  );
  test(
    'catalog keeps opaque document IDs and filters only Amazon dictionary tags',
    () {
      final result = parseKindleCatalog(
        utf8.encode(
          '''<response syncType="full"><sync_time>1</sync_time><add_update_list>
<meta_data><ASIN>opaque+/document</ASIN><cde_contenttype>PDOC</cde_contenttype><title>Il mio dizionario</title><authors><author>Autore</author></authors></meta_data>
<meta_data><ASIN>free</ASIN><cde_contenttype>EBOK</cde_contenttype><title>English</title><content_tags><tag>DICT</tag></content_tags></meta_data>
<meta_data><ASIN>paid</ASIN><cde_contenttype>EBOK</cde_contenttype><content_tags><tag>DICT</tag></content_tags><origins><origin><type>Purchase</type></origin></origins></meta_data>
</add_update_list></response>''',
        ),
      );
      final items = (result['items'] as List).map(object).toList();
      expect(items[0]['key'], 'PDOC:opaque+/document');
      expect(items[0]['is_amazon_dictionary'], isFalse);
      expect(items[1]['is_amazon_dictionary'], isTrue);
      expect(items[2]['is_amazon_dictionary'], isFalse);
      expect(items[2]['is_dictionary'], isTrue);
      expect(result['complete'], isTrue);
    },
  );
  for (final incremental in [false, true]) {
    test(
      'first synchronized catalog hides all dictionaries; incremental=$incremental',
      () async {
        final client = KindleClient(
          session: session(),
          client: MockClient(
            (_) async => http.Response('''
<response syncType="${incremental ? 'incremental' : 'full'}"><sync_time>2</sync_time><add_update_list>
<meta_data><ASIN>new</ASIN><cde_contenttype>PDOC</cde_contenttype><title>Novel</title></meta_data>
<meta_data><ASIN>paid</ASIN><cde_contenttype>EBOK</cde_contenttype><title>Reference</title><content_tags><tag>DICT</tag></content_tags><origins><origin><type>Purchase</type></origin></origins></meta_data>
</add_update_list></response>''', 200),
          ),
        );
        addTearDown(client.close);
        final result = await client.catalog(
          previous: incremental
              ? {
                  'complete': true,
                  'dictionary_filter_version': 1,
                  'sync_time': '1',
                  'items': [
                    {
                      'key': 'EBOK:legacy',
                      'title': 'Groot woordenboek Frans-Nederlands',
                    },
                    {'key': 'PDOC:existing', 'title': 'Existing book'},
                  ],
                }
              : null,
        );
        final titles = (result['items'] as List)
            .map((v) => object(v)['title'])
            .toList();
        expect(titles, incremental ? ['Existing book', 'Novel'] : ['Novel']);
      },
    );
  }
  test('Kindle acquisition dates survive full refreshes without becoming publication dates', () async {
    var requests = 0;
    final client = KindleClient(
      session: session(),
      client: MockClient((_) async {
        return http.Response(
          '''<response syncType="full"><sync_time>2</sync_time><add_update_list>
<meta_data><ASIN>book</ASIN><cde_contenttype>EBOK</cde_contenttype><title>Book</title><publication_date>1900-01-01</publication_date>${requests++ == 0 ? '<purchase_date>2026-11-07T12:00:00+0200</purchase_date>' : ''}</meta_data>
</add_update_list></response>''',
          200,
        );
      }),
    );
    addTearDown(client.close);
    final initial = await client.catalog(full: true);
    final refreshed = await client.catalog(full: true, previous: initial);
    final first = object((initial['items'] as List).single),
        second = object((refreshed['items'] as List).single);
    expect(first['added_at'], '2026-11-07T10:00:00.000Z');
    expect(second['added_at'], first['added_at']);
    expect(second['publication_date'], '1900-01-01');
  });
  test('legacy snapshots force a full metadata sync to recover lost dictionary classifications', () async {
    final client = KindleClient(
      session: session(),
      client: MockClient((request) async {
        expect(request.url.queryParameters, isNot(contains('last_sync_time')));
        return http.Response(
          '''<response syncType="full"><sync_time>2</sync_time><add_update_list>
<meta_data><ASIN>paid</ASIN><cde_contenttype>EBOK</cde_contenttype><title>Reference without a dictionary title</title><is_dictionary>true</is_dictionary><origins><origin><type>Purchase</type></origin></origins></meta_data>
<meta_data><ASIN>novel</ASIN><cde_contenttype>PDOC</cde_contenttype><title>Novel</title></meta_data>
</add_update_list></response>''',
          200,
        );
      }),
    );
    addTearDown(client.close);
    final result = await client.catalog(
      previous: {
        'complete': true,
        'sync_time': '1',
        'items': [
          {
            'key': 'EBOK:paid',
            'title': 'Reference without a dictionary title',
            'is_amazon_dictionary': false,
          },
        ],
      },
    );
    expect(result['dictionary_filter_version'], 1);
    expect((result['items'] as List).map((v) => object(v)['title']), ['Novel']);
  });
  test('newly discovered Kindle documents use this sync time when acquisition dates are absent', () async {
    final client = KindleClient(
      session: session(),
      client: MockClient(
        (_) async => http.Response(
          '''
<response><sync_time>2</sync_time><add_update_list><meta_data><ASIN>new</ASIN><cde_contenttype>PDOC</cde_contenttype><title>New document</title></meta_data></add_update_list></response>''',
          200,
        ),
      ),
    );
    addTearDown(client.close);
    final result = await client.catalog(
      previous: {
        'dictionary_filter_version': 1,
        'complete': true,
        'sync_time': '1',
        'fetched_at': '2020-01-01T00:00:00Z',
        'items': [],
      },
    );
    expect(
      object((result['items'] as List).single)['added_at'],
      result['fetched_at'],
    );
  });
  test('service failures contain no payload, tokens or signed URL', () async {
    final client = KindleClient(
      session: session(),
      client: MockClient(
        (_) async => http.Response('PRIVATE_TOKEN PRIVATE_TITLE', 403),
      ),
    );
    try {
      await expectLater(
        client.get(
          Uri.parse('https://cde-ta-g7g.amazon.com/test?secret=PRIVATE'),
        ),
        throwsA(
          isA<KindleFailure>().having(
            (e) => e.toString(),
            'safe diagnostic',
            isNot(contains('PRIVATE')),
          ),
        ),
      );
    } finally {
      client.close();
    }
  });
}
