import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/background_downloads.dart';
import 'package:kmreader/core/credentials.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:workmanager/workmanager.dart';

void verifyNativeBackgroundDownloads() {
  testWidgets(
    'OS scheduler restores a download with vault credentials and no visible reader window',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Background download verification')),
        ),
      );
      final directory = await Directory.systemTemp.createTemp(
        'kmreader-os-download-',
      );
      final store = LocalStore(
        sqlite3.open('${directory.path}/kmreader.sqlite'),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final id = 'native-background-${DateTime.now().microsecondsSinceEpoch}';
      final tag = BackgroundDownloads.profileTag(id);
      final job = BackgroundDownloads.jobId(id, 'native-book');
      const vault = SecureVault();
      final book = Book({
        'id': 'native-book',
        'name': 'Background fixture',
        'media': {'mediaProfile': 'PDF'},
      });
      var requests = 0;
      server.listen((request) async {
        if (request.headers.value('X-API-Key') !=
            'synthetic-native-background-key') {
          request.response.statusCode = 401;
        } else {
          requests++;
          request.response.headers.set('ETag', '"native-background-fixture"');
          request.response.add([1, 2, 3, 4, 5]);
        }
        await request.response.close();
      });
      try {
        store.saveServer(
          ServerProfile(
            id: id,
            name: 'Native fixture',
            url: 'http://127.0.0.1:${server.port}',
            email: '',
            authentication: Authentication.apiKey,
          ),
        );
        store.saveDownload(id, book, 'queued');
        await vault.write(id, 'synthetic-native-background-key');
        if (Platform.isAndroid) {
          await Workmanager().initialize(downloadCallbackDispatcher);
          await Workmanager().registerOneOffTask(
            job,
            'kmreader-download:$job',
            inputData: {
              'directory': directory.path,
              'server': id,
              'book': book.id,
            },
            constraints: Constraints(networkType: NetworkType.connected),
            existingWorkPolicy: ExistingWorkPolicy.replace,
            tag: tag,
          );
        } else {
          await BackgroundDownloads.channel.invokeMethod('schedule', {
            'id': tag,
            'directory': directory.path,
            'server': id,
            'charging': false,
          });
        }
        for (
          var i = 0;
          i < 450 && store.download(id, book.id)?['status'] != 'ready';
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          store.download(id, book.id)?['status'],
          'ready',
          reason: 'The native OS job must execute the actual worker, not just register successfully.',
        );
        expect(requests, greaterThanOrEqualTo(1));
        for (var i = 0; i < 50 && store.accountTransferring(id); i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(store.accountTransferring(id), false);
      } finally {
        if (Platform.isAndroid) {
          await Workmanager().cancelByTag(tag);
        } else {
          await BackgroundDownloads.channel.invokeMethod('cancel', tag);
        }
        await vault.delete(id);
        store.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
