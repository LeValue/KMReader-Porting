import 'dart:async';
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

void main() {
  final fixture = object(
    jsonDecode(
      File('test/support/kindle_protocol_fixture.json').readAsStringSync(),
    ),
  );
  final session = object(fixture['session']);
  final device = {
    'adp_token': session['adp_token'],
    'device_private_key': session['device_private_key'],
  };
  http.StreamedResponse jsonResponse(Json data, [int status = 200]) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(data))),
        status,
      );
  KindleImporter importer(
    Future<http.StreamedResponse> Function(http.BaseRequest, Stream<List<int>>)
    handler, {
    bool registered = true,
    Future<void> Function(KindleSession)? save,
  }) {
    final client = KindleClient(
      session: KindleSession({
        ...session,
        'expires': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
        if (registered) 'send_device': device,
      }),
      client: MockClient.streaming(handler),
      saveSession: save,
    );
    addTearDown(client.close);
    return KindleImporter(client);
  }

  final file = XFile.fromData(
    Uint8List.fromList(List.generate(200000, (i) => i % 256)),
    path: 'paper.epub',
  );
  Matcher failure(String code) =>
      isA<KindleFailure>().having((e) => e.code, 'code', code);
  Json uploadUrl({String? url}) => {
    'statusCode': 0,
    'stkToken': 'SYNTHETIC-UPLOAD',
    'uploadUrl':
        url ?? 'https://zme-caps.amazon.com/asset/SYNTHETIC?sig=temporary',
    'expiryTime': DateTime.now()
        .add(const Duration(minutes: 10))
        .millisecondsSinceEpoch,
  };

  test('import signature matches independent raw PKCS1 vector without changing CDE signing', () {
    final vector = object(
      jsonDecode(
        File('test/support/kindle_import_signature.json').readAsStringSync(),
      ),
    );
    final headers = kindleImportSigningHeaders((
      device,
      vector['path'],
      vector['body'],
      vector['timestamp'],
    ));
    expect(headers['X-ADP-Request-Digest'], vector['signature']);
    expect(headers['X-ADP-Authentication-Token'], device['adp_token']);
    final cde = kindleSigningHeaders(
      uri: Uri.https('kd.amazon.com', vector['path']),
      session: KindleSession(session),
      method: 'POST',
      body: utf8.encode(vector['body']),
      timestamp: vector['timestamp'],
    );
    expect(cde['x-adp-signature'], isNot(vector['signature']));
  });

  test('streams file unsigned, archives in Kindle and returns only after Amazon acceptance', () async {
    final calls = <String>[];
    var uploaded = 0, progress = 0;
    final service = importer((request, stream) async {
      calls.add(request.url.path);
      expect(request.followRedirects, false);
      if (request.method == 'PUT') {
        expect(request.contentLength, 200000);
        expect(
          request.headers.keys.any(
            (k) =>
                k.toLowerCase().contains('adp') ||
                k.toLowerCase() == 'authorization',
          ),
          false,
        );
        await for (final chunk in stream) {
          uploaded += chunk.length;
        }
        return http.StreamedResponse(const Stream.empty(), 200);
      }
      expect(request.url.host, 'kd.amazon.com');
      expect(
        request.headers['X-ADP-Authentication-Token'],
        device['adp_token'],
      );
      final data = object(
        jsonDecode(utf8.decode(await stream.expand((b) => b).toList())),
      );
      if (request.url.path.endsWith('upload-url')) {
        expect(data['fileSize'], 200000);
        return jsonResponse(uploadUrl());
      }
      expect(uploaded, 200000);
      expect(data['archive'], true);
      expect(data['targetDevices'], ['SYNTHETIC-DEVICE']);
      expect(object(data['documentMetadata'])['inputFormat'], 'epub');
      expect(object(data['documentMetadata'])['title'], 'My book');
      return jsonResponse({'statusCode': 0, 'sku': 'SYNTHETIC-DOCUMENT'});
    });
    expect(
      await service.upload(
        file,
        title: 'My book',
        author: 'Author',
        targets: ['SYNTHETIC-DEVICE'],
        cancel: KindleImportCancellation(),
        onProgress: (sent, _) => progress = sent,
      ),
      'SYNTHETIC-DOCUMENT',
    );
    expect(progress, 200000);
    expect(calls, [
      '/import/upload-url',
      '/asset/SYNTHETIC',
      '/import/kindle-doc/send-to-kindle',
    ]);
  });

  test('registers separate Send to Kindle device and persists it for subsequent requests', () async {
    var registrations = 0, saves = 0;
    final service = importer(
      (request, stream) async {
        final body = utf8.decode(await stream.expand((b) => b).toList());
        if (request.url.path.endsWith('registerDeviceWithToken')) {
          registrations++;
          expect(request.url.host, 'firs-ta-g7g.amazon.com');
          expect(body, contains('<deviceType>A1K6D1WRW0MALS</deviceType>'));
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                '<response><adp_token>${device['adp_token']}</adp_token><device_private_key>${device['device_private_key']}</device_private_key></response>',
              ),
            ),
            200,
          );
        }
        return jsonResponse({
          'statusCode': 0,
          'ownedDevices': [
            {
              'deviceName': 'My Kindle',
              'deviceSerialNumber': 'SYNTHETIC-DEVICE',
              'deviceCapabilities': {},
            },
          ],
        });
      },
      registered: false,
      save: (updated) async {
        saves++;
        expect(
          object(updated.json['send_device'])['adp_token'],
          device['adp_token'],
        );
        expect(updated.json['device_type'], session['device_type']);
      },
    );
    expect(
      (await service.devices(KindleImportCancellation())).single.name,
      'My Kindle',
    );
    await service.devices(KindleImportCancellation());
    expect(registrations, 1);
    expect(saves, 1);
  });

  for (final mode in ['lost_reply', 'server_error', 'missing_sku']) {
    test('delivery $mode is uncertain and never replayed', () async {
      var deliveries = 0;
      final service = importer((request, stream) async {
        await stream.drain<void>();
        if (request.url.path.endsWith('upload-url')) {
          return jsonResponse(uploadUrl());
        }
        if (request.method == 'PUT') {
          return http.StreamedResponse(const Stream.empty(), 200);
        }
        deliveries++;
        if (mode == 'lost_reply') {
          throw const SocketException('PRIVATE-RESPONSE');
        }
        return jsonResponse({
          'statusCode': 0,
        }, mode == 'server_error' ? 503 : 200);
      });
      await expectLater(
        service.upload(
          file,
          title: 'Private title',
          author: '',
          targets: ['device'],
          cancel: KindleImportCancellation(),
        ),
        throwsA(failure('import_delivery_uncertain')),
      );
      expect(deliveries, 1);
    });
  }

  test('cancellation after transfer prevents final delivery', () async {
    var deliveries = 0;
    final cancel = KindleImportCancellation();
    final service = importer((request, stream) async {
      await stream.drain<void>();
      if (request.url.path.endsWith('upload-url')) {
        return jsonResponse(uploadUrl());
      }
      if (request.method == 'PUT') {
        cancel.cancel();
        return http.StreamedResponse(const Stream.empty(), 200);
      }
      deliveries++;
      return jsonResponse({'statusCode': 0, 'sku': 'unexpected'});
    });
    await expectLater(
      service.upload(
        file,
        title: 'Title',
        author: '',
        targets: ['device'],
        cancel: cancel,
      ),
      throwsA(failure('import_cancelled')),
    );
    expect(deliveries, 0);
  });

  test(
    'untrusted presigned destinations and redirects cannot receive files',
    () async {
      var requests = 0;
      final service = importer((request, stream) async {
        requests++;
        await stream.drain<void>();
        return jsonResponse(uploadUrl(url: 'https://example.invalid/private'));
      });
      await expectLater(
        service.upload(
          file,
          title: 'Title',
          author: '',
          targets: ['device'],
          cancel: KindleImportCancellation(),
        ),
        throwsA(failure('delivery_address')),
      );
      expect(requests, 1);
    },
  );

  test('unsupported, empty, too large and incomplete submissions make no network requests', () async {
    final service = importer(
      (_, _) async => throw StateError('Unexpected request'),
    );
    for (final input in [
      (
        XFile.fromData(Uint8List(1), path: 'comic.cbz'),
        'Title',
        ['device'],
        'import_format',
      ),
      (
        XFile.fromData(Uint8List(0), path: 'empty.pdf'),
        'Title',
        ['device'],
        'import_size',
      ),
      (
        _SizedFile(kindleImportMaxBytes + 1),
        'Title',
        ['device'],
        'import_size',
      ),
      (file, '', ['device'], 'import_metadata'),
      (file, 'Title', <String>[], 'import_metadata'),
    ]) {
      await expectLater(
        service.upload(
          input.$1,
          title: input.$2,
          author: '',
          targets: input.$3,
          cancel: KindleImportCancellation(),
        ),
        throwsA(failure(input.$4)),
      );
    }
  });
}

class _SizedFile extends XFile {
  _SizedFile(this.size) : super('large.pdf');
  final int size;
  @override
  Future<int> length() async => size;
}
