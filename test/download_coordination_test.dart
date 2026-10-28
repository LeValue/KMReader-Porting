import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late LocalStore store;
  late ServerProfile profile;
  late Repository foreground;
  late Completer<void> release, started;
  late int files;
  final book = Book({
    'id': 'one',
    'name': 'Fixture',
    'media': {'mediaType': 'application/pdf', 'pagesCount': 1},
  });
  setUp(() async {
    release = Completer<void>();
    started = Completer<void>();
    files = 0;
    directory = Directory.systemTemp.createTempSync('download-coordination-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    store = LocalStore(sqlite3.open('${directory.path}/store.sqlite'));
    profile = ServerProfile(
      id: 'profile',
      name: 'Fixture',
      url: 'http://127.0.0.1:${server.port}',
      email: '',
      authentication: Authentication.apiKey,
    );
    foreground = Repository(
      profile: profile,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: profile.authentication,
        credential: '',
      ),
      store: store,
      directory: directory,
    );
  });
  tearDown(() async {
    await foreground.stopDownloadWork();
    store.close();
    await server.close(force: true);
    directory.deleteSync(recursive: true);
  });
  test('pause retains the pending request and resumes validated bytes with a fresh connection', () async {
    final opened = Completer<void>(), resume = Completer<void>();
    server.listen((request) async {
      try {
        if (request.uri.path.endsWith('/thumbnail')) {
          request.response.add([1]);
          await request.response.close();
          return;
        }
        files++;
        request.response.headers.set('ETag', '"v1"');
        request.response.bufferOutput = false;
        if (request.headers.value('Range') == 'bytes=2-') {
          request.response.statusCode = 206;
          request.response.headers.set('Content-Range', 'bytes 2-4/5');
          request.response.contentLength = 3;
          request.response.add([3, 4, 5]);
          await request.response.close();
          return;
        }
        request.response.contentLength = 5;
        request.response.add([1, 2]);
        await request.response.flush();
        opened.complete();
        await resume.future;
        request.response.add([3, 4, 5]);
        await request.response.close();
      } catch (_) {}
    });
    var done = false;
    final download = foreground.download(book);
    download.then((_) => done = true);
    await opened.future;
    final partial = File('${foreground.bookFile(book).path}.part');
    for (
      var i = 0;
      i < 100 && (!await partial.exists() || await partial.length() != 2);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    foreground.pauseDownloads();
    for (
      var i = 0;
      i < 100 && store.download(profile.id, book.id)?['status'] != 'paused';
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(store.download(profile.id, book.id)?['status'], 'paused');
    expect(done, false);
    expect(await partial.readAsBytes(), [1, 2]);
    resume.complete();
    foreground.resumeDownloads();
    await download;
    expect(files, 2);
    expect(done, true);
    expect(await foreground.bookFile(book).readAsBytes(), [1, 2, 3, 4, 5]);
    expect(store.download(profile.id, book.id)?['status'], 'ready');
  });
  test('a background repository refuses an active foreground lease before requesting bytes', () async {
    server.listen((request) async {
      try {
        if (request.uri.path.endsWith('/thumbnail')) {
          request.response.add([1]);
          await request.response.close();
          return;
        }
        files++;
        request.response.contentLength = 1;
        if (!started.isCompleted) started.complete();
        await release.future;
        request.response.add([1]);
        await request.response.close();
      } catch (_) {}
    });
    final download = foreground.download(book);
    await started.future;
    final workerStore = LocalStore(
      sqlite3.open('${directory.path}/store.sqlite'),
    );
    final background = Repository(
      profile: profile,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: profile.authentication,
        credential: '',
      ),
      store: workerStore,
      directory: directory,
      backgroundTransfer: true,
    );
    try {
      await expectLater(
        background.download(book),
        throwsA(isA<TransferBusy>()),
      );
      expect(files, 1);
    } finally {
      await background.stopDownloadWork();
      workerStore.close();
      release.complete();
    }
    await download;
    expect(store.download(profile.id, book.id)?['status'], 'ready');
  });
}
