import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/credentials.dart';
import 'package:kmreader/core/download_policy.dart';
import 'package:kmreader/core/download_worker.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

class _Vault implements CredentialVault {
  @override
  Future<String?> read(String id) async => 'synthetic-worker-key';
  @override
  Future<void> write(String id, String value) async {}
  @override
  Future<void> delete(String id) async {}
}

void main() {
  late Directory directory;
  late HttpServer server;
  late LocalStore store;
  late ServerProfile profile;
  final book = Book({
    'id': 'worker-book',
    'name': 'Fixture',
    'media': {'mediaProfile': 'PDF'},
  });
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('download-worker-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    store = LocalStore(sqlite3.open('${directory.path}/kmreader.sqlite'));
    profile = ServerProfile(
      id: 'worker',
      name: 'Fixture',
      url: 'http://127.0.0.1:${server.port}',
      email: '',
      authentication: Authentication.apiKey,
    );
    store.saveServer(profile);
    store.saveDownload(profile.id, book, 'queued');
  });
  tearDown(() async {
    store.close();
    await server.close(force: true);
    directory.deleteSync(recursive: true);
  });
  DownloadWorker worker({
    Duration budget = const Duration(minutes: 1),
    Future<TransferConditions> Function()? conditions,
  }) => DownloadWorker(
    directory: directory,
    server: profile.id,
    book: book.id,
    vault: _Vault(),
    budget: budget,
    conditions: conditions,
  );

  test('an independent worker restores persisted work and reads credentials from the vault', () async {
    var files = 0;
    server.listen((request) async {
      expect(request.headers.value('X-API-Key'), 'synthetic-worker-key');
      if (request.uri.path.endsWith('/file')) files++;
      request.response.add([1, 2, 3]);
      await request.response.close();
    });
    expect(await worker().run(), true);
    expect(files, 1);
    expect(store.download(profile.id, book.id)?['status'], 'ready');
    expect(await worker().run(), true);
    expect(files, 1);
    expect(store.transferring(profile.id, book.id), false);
  });
  test(
    'a timed-out worker aborts its connection and leaves retryable queued work',
    () async {
      final received = Completer<void>();
      server.listen((request) async {
        if (request.uri.path.endsWith('/thumbnail')) {
          request.response.add([1]);
          await request.response.close();
        } else {
          request.response.headers.set('ETag', '"stable"');
          request.response.bufferOutput = false;
          request.response.contentLength = 100;
          request.response.add([1, 2]);
          await request.response.flush();
          if (!received.isCompleted) received.complete();
        }
      });
      final task = worker(budget: const Duration(milliseconds: 300)).run();
      await received.future;
      expect(await task, false);
      expect(store.download(profile.id, book.id)?['status'], 'queued');
      expect(store.transferring(profile.id, book.id), false);
    },
  );
  test(
    'remote cancellation is not overwritten by worker timeout or cleanup',
    () async {
      final received = Completer<void>();
      server.listen((request) async {
        if (request.uri.path.endsWith('/thumbnail')) {
          request.response.add([1]);
          await request.response.close();
        } else {
          request.response.bufferOutput = false;
          request.response.contentLength = 100;
          request.response.add([1, 2]);
          await request.response.flush();
          if (!received.isCompleted) received.complete();
        }
      });
      final task = worker().run();
      await received.future;
      store.saveDownload(profile.id, book, 'cancelled');
      expect(await task, true);
      expect(store.download(profile.id, book.id)?['status'], 'cancelled');
      expect(store.transferring(profile.id, book.id), false);
    },
  );
  test(
    'offline, removed accounts and metered policy suppress network access',
    () async {
      var requests = 0;
      server.listen((request) async {
        requests++;
        await request.response.close();
      });
      store.setSetting('offline:${profile.id}', true);
      expect(await worker().run(), true);
      store.setSetting('offline:${profile.id}', false);
      store.setSetting(
        'downloadPolicy',
        const DownloadPolicy(unmetered: true).toJson(),
      );
      expect(
        await worker(
          conditions: () async => const TransferConditions(metered: true),
        ).run(),
        false,
      );
      store.removeServer(profile.id);
      expect(await worker().run(), true);
      expect(requests, 0);
    },
  );
}
