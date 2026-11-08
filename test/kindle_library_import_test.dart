import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/repository.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/kindle/kindle_import_page.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  testWidgets(
    'cloud library is the default and needs no device query or selection',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('kindle-cloud-ui-');
      final file = File(p.join(root.path, 'Cloud document.txt'))
        ..writeAsStringSync('Synthetic');
      final store = LocalStore(sqlite3.openInMemory());
      final session = object(
        object(
          jsonDecode(
            File('test/support/kindle_protocol_fixture.json')
                .readAsStringSync(),
          ),
        )['session'],
      );
      var sends = 0;
      final client = KindleClient(
        session: KindleSession({
          ...session,
          'send_device': {
            'adp_token': session['adp_token'],
            'device_private_key': session['device_private_key'],
          },
        }),
        client: MockClient((request) async {
          expect(request.url.path, isNot(endsWith('get-device-list')));
          if (request.url.path.endsWith('upload-url')) {
            return http.Response(
              '{"statusCode":0,"stkToken":"synthetic","uploadUrl":"https://zme-caps.amazon.com/asset"}',
              200,
            );
          }
          if (request.method == 'PUT') return http.Response('', 200);
          final body = object(jsonDecode(request.body));
          expect(body['archive'], true);
          expect(body['targetDevices'], isEmpty);
          sends++;
          return http.Response('{"statusCode":0,"sku":"SYNTHETIC"}', 200);
        }),
      );
      final repo = KindleRepository(
        profile: const ServerProfile(
          id: 'cloud-ui',
          name: 'Kindle',
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
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        selector,
        (_) async => [file.path],
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          selector,
          null,
        );
        repo.dispose();
        store.close();
        root.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(home: KindleImportPage(repository: repo)),
      );
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        true,
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.tap(find.text('Choose file'));
      for (
        var i = 0;
        i < 100 && find.text('Cloud document.txt').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      final send = find.byType(FilledButton);
      expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
      await tester.ensureVisible(send);
      await tester.tap(send);
      for (
        var i = 0;
        i < 100 &&
            find.textContaining('Accepted by Amazon.').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(sends, 1);
      expect(find.textContaining('Accepted by Amazon.'), findsOneWidget);
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
