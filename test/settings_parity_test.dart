import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/app_controller.dart';
import 'package:kmreader/core/client_log.dart';
import 'package:kmreader/core/media_cache.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/progress_gate.dart';
import 'package:kmreader/features/reader/reader_display.dart';
import 'package:kmreader/features/reader/reading_session.dart';
import 'package:kmreader/features/settings/reader_settings.dart';
import 'package:kmreader/ui/strings.dart';

import 'widget_test.dart' show MemoryVault;

const profile = ServerProfile(
  id: 'settings',
  name: 'Settings',
  url: 'https://example.invalid',
  email: '',
  authentication: Authentication.apiKey,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(Strings.initialize);
  late LocalStore store;
  late Directory directory;
  final repositories = <Repository>[];
  Repository repo({http.Client? client, ServerProfile account = profile}) {
    final repository = Repository(
      profile: account,
      store: store,
      directory: directory,
      api: KomgaApi(
        Uri.parse(account.url),
        authentication: Authentication.apiKey,
        credential: 'private-key',
        client: client ?? MockClient((_) async => http.Response('{}', 200)),
      ),
    );
    repositories.add(repository);
    return repository;
  }

  setUp(() {
    store = LocalStore(sqlite3.openInMemory());
    store.saveServer(profile);
    directory = Directory.systemTemp.createTempSync('kmreader-settings-');
    ClientLog.instance.clear();
  });
  tearDown(() {
    for (final repository in repositories) {
      repository.dispose();
    }
    repositories.clear();
    store.close();
    directory.deleteSync(recursive: true);
  });

  test('recording threshold protects unread/re-read opens, allows completion and stays open after recording', () {
    final unread = Book({
      'id': 'book',
      'media': {'pagesCount': 20},
    });
    final gate = ReaderProgressGate(unread, 3);
    expect(gate.allows(1), isFalse);
    expect(gate.allows(3), isFalse);
    expect(gate.allows(4), isTrue);
    expect(gate.allows(2), isTrue);
    final inProgress = ReaderProgressGate(
      Book({
        ...unread.json,
        'readProgress': {'page': 8},
      }),
      10,
    );
    expect(inProgress.allows(8), isFalse);
    expect(inProgress.allows(9), isTrue);
    final finished = ReaderProgressGate(
      Book({
        ...unread.json,
        'readProgress': {'completed': true, 'page': 20},
      }),
      3,
    );
    expect(finished.allows(1), isFalse);
    expect(finished.allows(20), isTrue);
    expect(
      ReaderProgressGate(
        Book({
          'media': {'pagesCount': 2},
        }),
        10,
      ).allows(2),
      isTrue,
    );
  });

  test('solo-cover spreads retain canonical pages and commit only the visible spread', () {
    final writes = <int>[];
    final session = ReadingSession(
      count: 5,
      initialPage: 1,
      preferences: const ReaderPreferences(spread: true, soloCover: true),
      onCommit: writes.add,
    );
    expect(session.itemCount, 3);
    expect(session.firstPage(0), 1);
    expect(session.visiblePages(0), 1);
    session.next();
    expect(session.page, 2);
    session.rendered(2);
    expect(writes, [3]);
    session.next();
    expect(session.page, 4);
    session.rendered(4);
    expect(writes, [3, 5]);
    expect(session.atEnd, isTrue);
    session.previous();
    expect(session.page, 2);
    session.go(3);
    expect(session.itemIndex, 1);
    session.dispose();
  });

  test('legacy media migration separates covers/pages without losing bytes or download progress', () async {
    final repository = repo();
    const cover = '/api/v1/books/book/thumbnail',
        page = '/api/v1/books/book/pages/1';
    await repository.imageDirectory.create(recursive: true);
    for (final path in [cover, page]) {
      File('${repository.imageDirectory.path}/${repository.fileKey(path)}')
          .writeAsBytesSync([1, 2, 3]);
      store.markImageStored(profile.id, path, 0);
    }
    final book = Book({'id': 'book', 'name': 'Book.pdf'});
    final source = repository.bookFile(book);
    await source.parent.create(recursive: true);
    await source.writeAsBytes([9, 8]);
    store.recordProgress(profile.id, book.id, {'page': 2});
    expect(
      (await repository.mediaCache.stats(MediaCacheKind.covers)).entries,
      1,
    );
    expect((await repository.mediaCache.stats(MediaCacheKind.pages)).bytes, 3);
    expect(repository.cachedFile(cover).readAsBytesSync(), [1, 2, 3]);
    await repository.clearImageCache(kind: MediaCacheKind.covers);
    expect(repository.cachedFile(cover).existsSync(), isFalse);
    expect(repository.cachedFile(page).existsSync(), isTrue);
    expect(source.readAsBytesSync(), [9, 8]);
    expect(store.pendingCount(profile.id), 1);
  });

  test('page/cover quotas are independent and the oldest media is evicted across accounts', () async {
    final first = repo();
    final secondProfile = ServerProfile(
      id: 'other',
      name: 'Other',
      url: profile.url,
      email: '',
      authentication: Authentication.apiKey,
    );
    store.saveServer(secondProfile);
    final second = repo(account: secondProfile);
    store.setSetting('maxCoverCacheSize', 128);
    const path = '/api/v1/books/book/thumbnail';
    Future<void> sparse(File file, int bytes, DateTime date) async {
      await file.parent.create(recursive: true);
      final output = await file.open(mode: FileMode.write);
      try {
        await output.truncate(bytes);
      } finally {
        await output.close();
      }
      await file.setLastModified(date);
    }

    final old = first.cachedFile(path), recent = second.cachedFile(path);
    await sparse(old, 80 * 1024 * 1024, DateTime(2000));
    await sparse(recent, 80 * 1024 * 1024, DateTime(2020));
    final page = first.cachedFile('/api/v1/books/book/pages/1');
    await sparse(page, 1024, DateTime(1999));
    await first.mediaCache.trim();
    expect(old.existsSync(), isFalse);
    expect(recent.existsSync(), isTrue);
    expect(page.existsSync(), isTrue);
    await first.clearImageCache(kind: MediaCacheKind.covers, allAccounts: true);
    expect(recent.existsSync(), isFalse);
    expect(page.existsSync(), isTrue);
  });

  test('clearing a cover while its response is in flight cannot repopulate its disk cache', () async {
    final started = Completer<void>(), response = Completer<http.Response>();
    final repository = repo(
      client: MockClient((_) {
        started.complete();
        return response.future;
      }),
    );
    const path = '/api/v1/books/book/thumbnail';
    final request = repository.image(path);
    await started.future;
    await repository.clearImageCache(kind: MediaCacheKind.covers);
    response.complete(http.Response.bytes([7, 8, 9], 200));
    expect(await request, [7, 8, 9]);
    expect(repository.cachedFile(path).existsSync(), isFalse);
  });

  test('completed-download cleanup waits for all readers and preserves an incognito session', () async {
    final repository = repo();
    final book = Book({
      'id': 'book',
      'name': 'Book.pdf',
      'media': {'pagesCount': 2},
    });
    final file = repository.bookFile(book);
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    store.saveDownload(profile.id, book, 'ready');
    store.setSetting('offlineAutoDeleteRead', true);
    repository.readerOpened(book.id);
    repository.readerOpened(book.id);
    repository.readerClosed(book, incognito: false);
    expect(file.existsSync(), isTrue);
    repository.readerClosed(book, incognito: false);
    repository.readerOpened(book.id);
    store.recordProgress(profile.id, book.id, {'page': 2, 'completed': true});
    await repository.readerCleanupSettled;
    expect(file.existsSync(), isTrue);
    repository.readerClosed(book, incognito: true);
    await repository.readerCleanupSettled;
    expect(file.existsSync(), isTrue);
    repository.readerOpened(book.id);
    repository.readerClosed(book, incognito: false);
    await repository.readerCleanupSettled;
    expect(file.existsSync(), isFalse);
    expect(store.download(profile.id, book.id), isNull);
    expect(store.progress(profile.id, book.id)?['completed'], true);
  });

  test(
    'SSE cancellation also releases a response that arrives after cancellation',
    () async {
      final started = Completer<void>();
      final response = Completer<http.StreamedResponse>();
      final released = Completer<void>();
      final bytes = StreamController<List<int>>(onCancel: released.complete);
      final repository = repo(
        client: MockClient.streaming((_, _) {
          started.complete();
          return response.future;
        }),
      );
      final subscription = repository.api.serverEvents().listen((_) {});
      await started.future;
      await subscription.cancel().timeout(const Duration(seconds: 1));
      response.complete(http.StreamedResponse(bytes.stream, 200));
      await released.future.timeout(const Duration(seconds: 1));
      await bytes.close();
    },
  );

  test('configured retries apply immediately to safe reads and never replay mutations', () async {
    var calls = 0;
    final repository = repo(
      client: MockClient(
        (_) async =>
            http.Response(calls++ == 0 ? '' : '{}', calls == 1 ? 503 : 200),
      ),
    );
    await expectLater(
      repository.api.request('/api/v1/libraries'),
      throwsA(isA<ApiFailure>()),
    );
    expect(calls, 1);
    calls = 0;
    store.setSetting('apiRetryCount', 2);
    expect(await repository.api.request('/api/v1/libraries'), {});
    expect(calls, 2);
    calls = 0;
    await expectLater(
      repository.api.request(
        '/api/v1/books/book/read-progress',
        method: 'PATCH',
        body: {'page': 1},
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(calls, 1);
  });

  test(
    'retry preferences also control foreground image and file GETs',
    () async {
      var calls = 0;
      final repository = repo(
        client: MockClient((_) async {
          calls++;
          return calls < 3
              ? http.Response('temporary', 503)
              : http.Response('image', 200);
        }),
      );
      store.setSetting('apiRetryCount', 0);
      await expectLater(
        repository.api.bytes('/image'),
        throwsA(isA<ApiFailure>()),
      );
      expect(calls, 1);
      calls = 0;
      store.setSetting('apiRetryCount', 2);
      expect(utf8.decode(await repository.api.bytes('/image')), 'image');
      expect(calls, 3);
      calls = 0;
      store.setSetting('apiRetryCount', 0);
      final target = File('${directory.path}/foreground.bin');
      await expectLater(
        repository.api.download('/file', target),
        throwsA(isA<ApiFailure>()),
      );
      expect(calls, 1);
      expect(target.existsSync(), false);
      calls = 0;
      store.setSetting('apiRetryCount', 2);
      await repository.api.download('/file', target);
      expect(calls, 3);
      expect(await target.readAsString(), 'image');
    },
  );

  testWidgets(
    'authentication timeout follows the configured value rather than the request timeout',
    (tester) async {
      final response = Completer<http.Response>();
      final repository = repo(client: MockClient((_) => response.future));
      store.setSetting('authTimeout', 1);
      store.setSetting('requestTimeout', 60);
      repository.api.authenticating = true;
      Object? failure;
      final request = repository.api
          .request('/api/v2/users/me')
          .then<void>(
            (_) {},
            onError: (Object error) {
              failure = error;
            },
          );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(failure, isA<ApiFailure>());
      expect((failure as ApiFailure).offline, isTrue);
      response.complete(http.Response('{}', 200));
      await request;
    },
  );

  test('real-time settings retain task status while disabling automatic catalog invalidation and can disconnect/reconnect', () async {
    var streams = 0;
    var events = StreamController<List<int>>();
    final repository = repo(
      client: MockClient.streaming((_, _) async {
        streams++;
        return http.StreamedResponse(events.stream, 200);
      }),
    );
    store.setSetting('enableSSEAutoRefresh', false);
    store.setSetting('enableSSENotify', true);
    repository.listen();
    await Future<void>.delayed(Duration.zero);
    events.add(
      utf8.encode(
        'event: BookAdded\ndata: {"bookId":"book"}\n\nevent: TaskQueueStatus\ndata: {"count":5}\n\n',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(repository.taskQueueStatus.value['count'], 5);
    expect(repository.contentRevision, 0);
    events.add(utf8.encode('event: TaskQueueStatus\ndata: {"count":0}\n\n'));
    await Future<void>.delayed(Duration.zero);
    expect(repository.eventNotices.value, 'Tasks completed');
    store.setSetting('enableSSE', false);
    await repository.applyEventPreferences();
    expect(streams, 1);
    await events.close();
    events = StreamController<List<int>>();
    store.setSetting('enableSSE', true);
    await repository.applyEventPreferences();
    await Future<void>.delayed(Duration.zero);
    expect(streams, 2);
    events.add(utf8.encode('event: TaskQueueStatus\ndata: {"count":7}\n\n'));
    await Future<void>.delayed(Duration.zero);
    expect(repository.taskQueueStatus.value['count'], 7);
    repository.dispose();
    repositories.remove(repository);
    await events.close();
  });

  test('diagnostics remain bounded and API logging excludes credential, URL and body data', () async {
    final repository = repo(
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    await repository.api.request(
      '/api/v1/private-book-id',
      method: 'POST',
      body: {'private': 'book text'},
    );
    expect(ClientLog.instance.exported, contains('POST HTTP 200'));
    for (final secret in [
      'private-key',
      'private-book-id',
      'book text',
      'example.invalid',
    ]) {
      expect(ClientLog.instance.exported, isNot(contains(secret)));
    }
    for (var i = 0; i < 505; i++) {
      ClientLog.instance.add('info', 'test', '$i');
    }
    expect(ClientLog.instance.entries.length, 500);
    expect(ClientLog.instance.entries.first.message, '5');
    ClientLog.instance.clear();
    expect(ClientLog.instance.exported, isEmpty);
  });

  test(
    'app icon selection persists only after a successful native update',
    () async {
      const channel = MethodChannel('dev.levalue.kmreader/privacy');
      final app = AppController(
        store: store,
        directory: directory,
        vault: MemoryVault(),
      );
      addTearDown(app.dispose);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw PlatformException(code: 'icon'),
          );
      await expectLater(
        app.setAppIcon('classic'),
        throwsA(isA<PlatformException>()),
      );
      expect(store.setting<String>('appIcon'), isNull);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expectSync(call.method, 'setAppIcon');
            expectSync(call.arguments, 'classic');
            return null;
          });
      await app.setAppIcon('classic');
      expect(store.setting<String>('appIcon'), 'classic');
    },
  );

  testWidgets(
    'automatic deletion requires explicit confirmation before enabling',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ReaderGeneralSettingsPage(repository: repo())),
      );
      final toggle = find.byKey(
        const ValueKey('preference::offlineAutoDeleteRead'),
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(store.setting<bool>('offlineAutoDeleteRead'), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.setting<bool>('offlineAutoDeleteRead'), isNull);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(store.setting<bool>('offlineAutoDeleteRead'), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final width in [320.0, 1280.0]) {
    testWidgets(
      'DIVINA defaults persist compatible layout and split choices at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(home: DivinaSettingsPage(repository: repo())),
        );
        final layout = find.byKey(
          const ValueKey('preference:readerDefault:pageLayout'),
        );
        await tester.ensureVisible(layout);
        await tester.pumpAndSettle();
        await tester.tap(layout);
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<Object>, 'Dual Page').last,
        );
        await tester.pumpAndSettle();
        expect(
          ReaderPreferences.fromJson(
            object(store.setting<dynamic>('readerDefault')),
          ).spread,
          isTrue,
        );
        expect(
          find.byKey(const ValueKey('preference:readerDefault:splitWide')),
          findsNothing,
        );
        await tester.tap(layout);
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<Object>, 'Auto').last,
        );
        await tester.pumpAndSettle();
        final split = find.byKey(
          const ValueKey('preference:readerDefault:splitWide'),
        );
        await tester.ensureVisible(split);
        await tester.pumpAndSettle();
        await tester.tap(split);
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .widgetWithText(CheckedPopupMenuItem<Object>, 'Left to Right')
              .last,
        );
        await tester.pumpAndSettle();
        final restored = ReaderPreferences.fromJson(
          object(store.setting<dynamic>('readerDefault')),
        );
        expect(restored.splitWide, 'ltr');
        expect(restored.spread, isFalse);
        expect(restored.pageLayout, 'single');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'theme presets restore typography without overwriting flow or gestures',
    (tester) async {
      store.setSetting('epubDefault', {
        'flow': 'scrolled',
        'fontSize': 22.0,
        'tapMode': 'edge',
      });
      await tester.pumpWidget(
        MaterialApp(home: EpubThemeSettingsPage(repository: repo())),
      );
      await tester.tap(find.text('Save as Preset'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Evening');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final saved = object(
        (store.setting<List<dynamic>>('epubPresets')!).single,
      );
      expect(object(saved['value'])['fontSize'], 22.0);
      expect(object(saved['value']).containsKey('flow'), isFalse);
      store.setSetting('epubDefault', {
        'flow': 'paged',
        'fontSize': 30.0,
        'tapMode': 'kindle',
      });
      await tester.tap(find.text('Load Preset'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Evening'));
      await tester.pumpAndSettle();
      final restored = object(store.setting<dynamic>('epubDefault'));
      expect(restored['fontSize'], 22.0);
      expect(restored['flow'], 'paged');
      expect(restored['tapMode'], 'kindle');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'EPUB flow and advanced layout expose only relevant persisted controls',
    (tester) async {
      store.setSetting('epubDefault', {
        'flow': 'paged',
        'advancedLayout': false,
      });
      await tester.pumpWidget(
        MaterialApp(home: EpubSettingsPage(store: store)),
      );
      final flow = find.byKey(const ValueKey('preference:epubDefault:flow'));
      await tester.tap(flow);
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<Object>, 'Continuous').last,
      );
      await tester.pumpAndSettle();
      expect(object(store.setting<dynamic>('epubDefault'))['flow'], 'scrolled');
      expect(
        find.byKey(const ValueKey('preference:epubDefault:animate')),
        findsOneWidget,
      );
      final scroll = find.byKey(
        const ValueKey('preference:epubDefault:tapScroll'),
      );
      await tester.scrollUntilVisible(
        scroll,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(scroll, findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(home: EpubThemeSettingsPage(repository: repo())),
      );
      await tester.pumpAndSettle();
      final advanced = find.byKey(
        const ValueKey('preference:epubDefault:advancedLayout'),
      );
      await tester.scrollUntilVisible(
        advanced,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('preference:epubDefault:lineHeight')),
        findsNothing,
      );
      await tester.tap(advanced);
      await tester.pumpAndSettle();
      final height = find.byKey(
        const ValueKey('preference:epubDefault:lineHeight'),
      );
      await tester.scrollUntilVisible(
        height,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(height, findsOneWidget);
      expect(
        object(store.setting<dynamic>('epubDefault'))['advancedLayout'],
        true,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'native Windows fullscreen remains owned until the active reader releases it',
    (tester) async {
      final values = <bool>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ReaderDisplay.channel, (call) async {
            if (call.method == 'setFullscreen') {
              values.add(call.arguments as bool);
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ReaderDisplay.channel, null),
      );
      var active = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, change) {
              update = change;
              return TickerMode(
                enabled: active,
                child: const ReaderDisplay(
                  fullscreen: true,
                  child: ReaderDisplay(child: Scaffold()),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      expect(values, [true]);
      update(() => active = false);
      await tester.pump();
      expect(values, [true, false]);
      update(() => active = true);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(values, [true, false, true, false]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
