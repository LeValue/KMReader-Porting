import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/import.dart';
import 'package:kmreader/core/models.dart';

import 'support/kindle_web_fixture.dart';

void main() {
  final session = object(
    object(
      jsonDecode(
        File('test/support/kindle_protocol_fixture.json').readAsStringSync(),
      ),
    )['session'],
  );
  for (final outcome in [
    'accepted',
    'lost_reply',
    'empty_reply',
    'server_error',
  ]) {
    test(
      'website STK $outcome uses existing account and never replays delivery',
      () async {
        var deliveries = 0, exchanges = 0, uploaded = 0;
        final bytes = Uint8List.fromList(List.generate(4096, (i) => i % 256));
        final client = KindleClient(
          session: KindleSession({...session, 'expires': 0}),
          client: MockClient((request) async {
            expect(request.url.host, isNot('firs-ta-g7g.amazon.com'));
            expect(
              request.headers.keys.any((k) => k.toLowerCase().contains('adp')),
              false,
            );
            if (request.url.path == '/ap/exchangetoken/cookies') {
              exchanges++;
              expect(
                request.bodyFields['source_token'],
                session['refresh_token'],
              );
            }
            final bootstrap = kindleWebFixture(request);
            if (bootstrap != null) return bootstrap;
            if (request.url.path == '/sendtokindle/get-device-list') {
              expect(request.headers['cookie'], 'session-id=synthetic-cookie');
              expect(request.headers['anti-csrftoken-a2z'], 'synthetic-csrf');
              return http.Response('{"ownedDevices":[]}', 200);
            }
            if (request.url.path == '/sendtokindle/init') {
              expect(
                object(jsonDecode(request.body))['fileSize'],
                bytes.length,
              );
              return http.Response(
                '{"stkToken":"synthetic","uploadUrl":"https://zme-caps.amazon.com/asset"}',
                200,
              );
            }
            if (request.method == 'PUT') {
              expect(request.headers['cookie'], isNull);
              expect(request.headers['anti-csrftoken-a2z'], isNull);
              expect(request.headers['content-type'], '');
              expect(request.bodyBytes, bytes);
              uploaded = request.bodyBytes.length;
              return http.Response('', 200);
            }
            expect(request.url.path, '/sendtokindle/send-v2');
            expect(uploaded, bytes.length);
            deliveries++;
            final body = object(jsonDecode(request.body));
            expect(body['archive'], true);
            expect(body['deviceList'], isEmpty);
            expect(body['dataType'], 'application/epub+zip');
            if (outcome == 'lost_reply') throw const SocketException('PRIVATE');
            if (outcome == 'server_error') return http.Response('PRIVATE', 503);
            return http.Response(
              outcome == 'empty_reply' ? '{}' : '{"sku":"SYNTHETIC"}',
              200,
            );
          }),
        );
        addTearDown(client.close);
        final importer = KindleImporter(client);
        expect(await importer.devices(KindleImportCancellation()), isEmpty);
        final result = importer.upload(
          XFile.fromData(bytes, path: 'synthetic.epub'),
          title: 'Synthetic',
          author: 'Synthetic',
          targets: [],
          cancel: KindleImportCancellation(),
        );
        if (outcome == 'accepted') {
          expect(await result, 'SYNTHETIC');
        } else {
          await expectLater(
            result,
            throwsA(
              isA<KindleFailure>().having(
                (e) => e.code,
                'code',
                'import_delivery_uncertain',
              ),
            ),
          );
        }
        expect(deliveries, 1);
        expect(exchanges, 1);
      },
    );
  }

  test(
    'CSRF presence alone never establishes an authenticated account',
    () async {
      final client = KindleClient(
        session: KindleSession(session),
        client: MockClient((request) async {
          if (request.url.path.endsWith('checkAuth')) {
            return http.Response('{"isAuthed":false}', 200);
          }
          final bootstrap = kindleWebFixture(request);
          if (bootstrap != null) return bootstrap;
          fail('An unauthenticated account must not submit any document');
        }),
      );
      addTearDown(client.close);
      await expectLater(
        KindleImporter(client).devices(KindleImportCancellation()),
        throwsA(
          isA<KindleFailure>().having(
            (e) => e.stage,
            'stage',
            'web_authentication',
          ),
        ),
      );
    },
  );
}
