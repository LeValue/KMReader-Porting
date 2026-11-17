import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/background_downloads.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

class _Coordinator extends BackgroundDownloads {
  _Coordinator(super.store, super.directory);
  @override
  bool get supported => true;
}

void main() {
  testWidgets(
    'idle coordinator reduces probes and stops polling while hidden',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('energy-test-');
      final store = LocalStore(sqlite3.openInMemory());
      final coordinator = _Coordinator(store, directory);
      var probes = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        BackgroundDownloads.channel,
        (call) async {
          if (call.method == 'conditions') probes++;
          return {'connected': true, 'metered': false, 'charging': false};
        },
      );
      try {
        await coordinator.initialize();
        await coordinator
            .initialize(); // Must not register duplicate observers/timers.
        expect(probes, 1);
        await tester.pump(const Duration(seconds: 10));
        expect(probes, 1);
        await tester.pump(const Duration(seconds: 5));
        expect(probes, 2);
        coordinator.didChangeAppLifecycleState(AppLifecycleState.hidden);
        await tester.pump(const Duration(minutes: 2));
        expect(probes, 2);
        coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
        expect(probes, 3);
        await tester.pump(const Duration(seconds: 15));
        expect(probes, 4);
        coordinator.dispose();
        await tester.pump(const Duration(minutes: 1));
        expect(probes, 4);
      } finally {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          BackgroundDownloads.channel,
          null,
        );
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'background disabled blocks transfers, enabled leaves them permitted',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('transfer-energy-');
      final store = LocalStore(sqlite3.openInMemory())
        ..setSetting('enableSSE', false);
      final coordinator = _Coordinator(store, directory);
      final repo = Repository(
        profile: const ServerProfile(
          id: 'synthetic',
          name: 'Fixture',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.apiKey,
        ),
        api: KomgaApi(
          Uri.parse('https://example.invalid'),
          authentication: Authentication.apiKey,
          credential: '',
        ),
        store: store,
        directory: directory,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        BackgroundDownloads.channel,
        (_) async => {'connected': true, 'metered': false, 'charging': true},
      );
      try {
        await coordinator.initialize();
        coordinator.attach(repo);
        store.setSetting('downloadPolicy', {'background': false});
        expect(repo.canTransfer!(), true);
        coordinator.didChangeAppLifecycleState(AppLifecycleState.paused);
        expect(repo.canTransfer!(), false);
        coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
        expect(repo.canTransfer!(), true);
        store.setSetting('downloadPolicy', {'background': true});
        coordinator.didChangeAppLifecycleState(AppLifecycleState.paused);
        expect(repo.canTransfer!(), true);
        coordinator.dispose();
        expect(repo.canTransfer, isNull);
        await tester.pump(const Duration(seconds: 1));
      } finally {
        repo.dispose();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          BackgroundDownloads.channel,
          null,
        );
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test('a header timeout aborts its underlying HTTP request', () async {
    var aborted = false;
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: '',
      client: MockClient.streaming((request, _) async {
        await (request as http.Abortable).abortTrigger;
        aborted = true;
        throw http.RequestAbortedException();
      }),
    );
    try {
      await expectLater(
        api.send('/slow', responseTimeout: const Duration(milliseconds: 1)),
        throwsA(isA<ApiFailure>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(aborted, true);
    } finally {
      api.close();
    }
  });

  test('resuming revalidates cached covers conditionally instead of discarding them', () async {
    final directory = Directory.systemTemp.createTempSync('cover-resume-');
    final store = LocalStore(sqlite3.openInMemory())
      ..setSetting('enableReadListSync', false);
    var calls = 0;
    final checked = Completer<void>();
    final events = StreamController<List<int>>();
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: '',
      client: MockClient.streaming((request, _) async {
        if (request.url.path.contains('/sse/')) {
          return http.StreamedResponse(events.stream, 200);
        }
        calls++;
        if (calls == 1) {
          return http.StreamedResponse(
            Stream.value([1, 2, 3]),
            200,
            headers: {'etag': 'synthetic-v1'},
          );
        }
        expect(request.headers['If-None-Match'], 'synthetic-v1');
        checked.complete();
        return http.StreamedResponse(const Stream.empty(), 304);
      }),
    );
    final repo = Repository(
      profile: const ServerProfile(
        id: 'synthetic',
        name: 'Fixture',
        url: 'https://example.invalid',
        email: '',
        authentication: Authentication.apiKey,
      ),
      api: api,
      store: store,
      directory: directory,
    );
    try {
      const path = '/api/v1/books/book/thumbnail';
      expect(await repo.image(path), [1, 2, 3]);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      repo.setForeground(false);
      repo.setForeground(true);
      expect(repo.imageChanges.value, contains(Repository.resumedCovers));
      expect(await repo.image(path), [1, 2, 3]);
      await checked.future.timeout(const Duration(seconds: 2));
      expect(calls, 2);
      expect(await repo.cachedFile(path).exists(), true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } finally {
      repo.dispose();
      await events.close();
      store.close();
      directory.deleteSync(recursive: true);
    }
  });

  test(
    'background SSE cancellation preserves event ID and reconciles on resume',
    () async {
      final directory = Directory.systemTemp.createTempSync('sse-energy-');
      final store = LocalStore(sqlite3.openInMemory())
        ..setSetting('enableReadListSync', false);
      final streams = <StreamController<List<int>>>[];
      final headers = <String?>[];
      final api = KomgaApi(
        Uri.parse('https://example.invalid'),
        authentication: Authentication.apiKey,
        credential: '',
        client: MockClient.streaming((request, _) async {
          headers.add(request.headers['Last-Event-ID']);
          final stream = StreamController<List<int>>();
          streams.add(stream);
          return http.StreamedResponse(stream.stream, 200);
        }),
      );
      final repo = Repository(
        profile: const ServerProfile(
          id: 'synthetic',
          name: 'Fixture',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.apiKey,
        ),
        api: api,
        store: store,
        directory: directory,
      );
      try {
        repo.listen();
        await Future<void>.delayed(Duration.zero);
        streams.first.add(
          utf8.encode('event: heartbeat\nid: saved-id\ndata: {}\n\n'),
        );
        await Future<void>.delayed(Duration.zero);
        repo.setForeground(false);
        await Future<void>.delayed(Duration.zero);
        expect(streams.first.hasListener, false);
        repo.listen();
        await Future<void>.delayed(Duration.zero);
        expect(streams, hasLength(1));
        final revision = repo.contentRevision;
        repo.setForeground(true);
        await Future<void>.delayed(Duration.zero);
        expect(repo.contentRevision, revision + 1);
        expect(streams, hasLength(2));
        expect(headers.last, 'saved-id');
        repo.setForeground(false);
        store.setSetting('enableSSEAutoRefresh', false);
        final unchanged = repo.contentRevision;
        repo.setForeground(true);
        await Future<void>.delayed(Duration.zero);
        expect(repo.contentRevision, unchanged);

        repo.setForeground(true);
        expect(streams, hasLength(3));
      } finally {
        repo.dispose();
        for (final stream in streams) {
          await stream.close();
        }
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
