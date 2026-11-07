import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/repository.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/kindle/kindle_import_page.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  for (final scenario in ['accepted', 'uncertain', 'devices_error']) {
    final accepted = scenario == 'accepted';
    final deviceError = scenario == 'devices_error';
    testWidgets(
      'file picker -> $scenario; retains failures and cannot send twice',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final root = Directory.systemTemp.createTempSync('kindle-import-ui-');
        final file = File(p.join(root.path, 'Local document.txt'))
          ..writeAsStringSync('Synthetic document');
        final store = LocalStore(sqlite3.openInMemory());
        final protocol = object(
          jsonDecode(
            File('test/support/kindle_protocol_fixture.json')
                .readAsStringSync(),
          ),
        );
        final data = object(protocol['session']);
        var deliveries = 0;
        final client = KindleClient(
          session: KindleSession({
            ...data,
            'expires': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
            'send_device': {
              'adp_token': data['adp_token'],
              'device_private_key': data['device_private_key'],
            },
          }),
          client: MockClient((request) async {
            if (request.url.path.endsWith('get-device-list')) {
              if (deviceError) return http.Response('PRIVATE SERVER BODY', 503);
              return http.Response(
                jsonEncode({
                  'statusCode': 0,
                  'ownedDevices': [
                    {
                      'deviceSerialNumber': 'SYNTHETIC-TARGET',
                      'deviceName': 'My Kindle',
                    },
                  ],
                }),
                200,
              );
            }
            if (request.url.path.endsWith('upload-url')) {
              return http.Response(
                jsonEncode({
                  'statusCode': 0,
                  'stkToken': 'token',
                  'uploadUrl': 'https://zme-caps.amazon.com/asset/SYNTHETIC',
                }),
                200,
              );
            }
            if (request.method == 'PUT') return http.Response('', 200);
            deliveries++;
            final body = object(jsonDecode(request.body));
            expect(body['targetDevices'], ['SYNTHETIC-TARGET']);
            if (!accepted) throw const SocketException('Lost response');
            return http.Response(
              '{"statusCode":0,"sku":"SYNTHETIC-DOCUMENT"}',
              200,
            );
          }),
        );
        final repo = KindleRepository(
          profile: const ServerProfile(
            id: 'kindle-ui',
            name: 'Chosen Kindle account',
            url: 'https://www.amazon.it',
            email: '',
            authentication: Authentication.apiKey,
            source: 'kindle',
          ),
          store: store,
          directory: root,
          client: client,
        )..setOffline(true);
        const selector = MethodChannel('plugins.flutter.io/file_selector');
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(selector, (_) async => [file.path]);
        addTearDown(() {
          messenger.setMockMethodCallHandler(selector, null);
          repo.dispose();
          store.close();
          root.deleteSync(recursive: true);
        });
        await tester.pumpWidget(
          MaterialApp(home: KindleImportPage(repository: repo)),
        );
        // RSA signing runs in a real isolate; let external futures finish.
        for (
          var i = 0;
          i < 12 && find.text('My Kindle').evaluate().isEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump();
        }
        if (deviceError) {
          expect(find.textContaining('HTTP 503'), findsOneWidget);
          expect(find.textContaining('PRIVATE SERVER BODY'), findsNothing);
          await tester.tap(find.text('Choose file'));
          for (
            var i = 0;
            i < 100 && find.text('Local document.txt').evaluate().isEmpty;
            i++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)),
            );
            await tester.pump();
          }
          expect(find.text('Local document.txt'), findsOneWidget);
          expect(find.textContaining('HTTP 503'), findsOneWidget);
          expect(find.text('Authorize Send to Kindle'), findsOneWidget);
          expect(
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull,
          );
          await tester.pumpWidget(const SizedBox());
          return;
        }
        expect(find.text('My Kindle'), findsOneWidget);
        expect(find.text('Chosen Kindle account'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        await tester.tap(find.text('Choose file'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.text('My Kindle'));
        await tester.pump();
        final button = find.byType(FilledButton);
        expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
        await tester.ensureVisible(button);
        await tester.tap(button);
        for (var i = 0; i < 20 && deliveries == 0; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump();
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(deliveries, 1);
        expect(tester.widget<FilledButton>(button).onPressed, isNull);
        expect(
          find.textContaining(
            accepted
                ? 'Accepted by Amazon.'
                : 'Amazon did not confirm delivery.',
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
