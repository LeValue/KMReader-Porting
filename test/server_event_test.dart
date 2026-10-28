import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/server_event.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('SSE decoding preserves split UTF-8, multiline data and IDs, ignoring comments and truncated events', () async {
    final bytes = utf8.encode(
      '\uFEFF: heartbeat\r\nid: 42\r\nevent: TaskQueueStatus\r\ndata: {"count": 3,\r\ndata: "countByType": {"Analyze": 3}}\r\n\r\nevent: BookChanged\nid: invalid\u0000id\ndata: {"bookId":"café"}\n\nevent: BookDeleted\ndata: {"bookId":"incomplete"}',
    );
    final events = await decodeServerEvents(
      Stream.fromIterable(bytes.map((byte) => [byte])),
    ).toList();
    expect(events, hasLength(2));
    expect(events.first.type, 'TaskQueueStatus');
    expect(events.first.object?['count'], 3);
    expect(events.last.id, '42');
    expect(events.last.object?['bookId'], 'café');
  });
  test(
    'oversized SSE payloads fail before dispatching an incomplete update',
    () async {
      final bytes = utf8.encode(
        'event: BookChanged\ndata: ${'x' * (1024 * 1024 + 1)}\n\n',
      );
      await expectLater(
        decodeServerEvents(Stream.value(bytes)).toList(),
        throwsFormatException,
      );
    },
  );
  test('SSE reconnect carries the last complete event ID', () async {
    final api = KomgaApi(
      Uri.parse('https://example.invalid'),
      authentication: Authentication.apiKey,
      credential: '',
      client: MockClient((request) async {
        expect(request.headers['Last-Event-ID'], '42');
        expect(request.headers['Accept'], 'text/event-stream');
        return http.Response(
          'id: 43\nevent: BookChanged\ndata: {"bookId":"b"}\n\n',
          200,
        );
      }),
    );
    try {
      expect((await api.serverEvents(lastEventId: '42').first).id, '43');
    } finally {
      api.close();
    }
  });
  test('thumbnail SSE invalidates only its image and a late worker cannot restore stale bytes', () async {
    final directory = Directory.systemTemp.createTempSync('thumbnail-event-');
    final store = LocalStore(sqlite3.open('${directory.path}/db.sqlite'));
    final otherStore = LocalStore(sqlite3.open('${directory.path}/db.sqlite'));
    const profile = ServerProfile(
      id: 's',
      name: 'Fixture',
      url: 'https://example.invalid',
      email: '',
      authentication: Authentication.apiKey,
    );
    const path = '/api/v1/books/one/thumbnail',
        other = '/api/v1/books/two/thumbnail';
    final events = StreamController<List<int>>();
    final oldResponse = Completer<http.StreamedResponse>(),
        oldStarted = Completer<void>();
    final api = KomgaApi(
      Uri.parse(profile.url),
      authentication: Authentication.apiKey,
      credential: '',
      client: MockClient.streaming((request, _) async {
        if (request.url.path == '/sse/v1/events') {
          return http.StreamedResponse(events.stream, 200);
        }
        return http.StreamedResponse(
          Stream.value(request.url.path == other ? [9] : [2]),
          200,
        );
      }),
    );
    final workerApi = KomgaApi(
      Uri.parse(profile.url),
      authentication: Authentication.apiKey,
      credential: '',
      client: MockClient.streaming((request, _) async {
        oldStarted.complete();
        return oldResponse.future;
      }),
    );
    final repository = Repository(
      profile: profile,
      api: api,
      store: store,
      directory: directory,
    );
    final worker = Repository(
      profile: profile,
      api: workerApi,
      store: otherStore,
      directory: directory,
      backgroundTransfer: true,
    );
    try {
      repository.listen();
      expect(await repository.image(other), [9]);
      final old = worker.image(path);
      await oldStarted.future;
      final changed = Completer<void>();
      repository.imageChanges.addListener(() {
        if (!changed.isCompleted) changed.complete();
      });
      events.add(
        utf8.encode(
          'event: ThumbnailBookAdded\ndata: {"bookId":"one","selected":true}\n\n',
        ),
      );
      await changed.future.timeout(const Duration(seconds: 3));
      expect(repository.imageChanges.value, {path});
      expect(repository.contentRevision, 0);
      expect(await repository.image(path), [2]);
      oldResponse.complete(http.StreamedResponse(Stream.value([1]), 200));
      expect(await old, [1]);
      expect(await repository.cachedFile(path).readAsBytes(), [2]);
      expect(await repository.image(path), [2]);
      expect(await repository.image(other), [9]);
      expect(await repository.cachedFile(other).exists(), true);
    } finally {
      if (!oldResponse.isCompleted) {
        oldResponse.complete(http.StreamedResponse(Stream.value([1]), 200));
      }
      await worker.stopDownloadWork();
      await repository.stopDownloadWork();
      await events.close();
      store.close();
      otherStore.close();
      directory.deleteSync(recursive: true);
    }
  });
  test('task queue events update their own durable snapshot without reloading catalogs', () async {
    final directory = Directory.systemTemp.createTempSync('task-event-');
    final store = LocalStore(sqlite3.openInMemory());
    final events = StreamController<List<int>>();
    const profile = ServerProfile(
      id: 's',
      name: 'Fixture',
      url: 'https://example.invalid',
      email: '',
      authentication: Authentication.apiKey,
    );
    final repository = Repository(
      profile: profile,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: Authentication.apiKey,
        credential: '',
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(events.stream, 200),
        ),
      ),
      store: store,
      directory: directory,
    );
    try {
      var notifications = 0;
      repository.taskQueueStatus.addListener(() => notifications++);
      repository.listen();
      for (var i = 0; i < 100; i++) {
        events.add(
          utf8.encode(
            'event: TaskQueueStatus\ndata: {"count":5,"countByType":{"Analyze":5}}\n\n',
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(notifications, 1);
      expect(repository.contentRevision, 0);
      expect(repository.taskQueueStatus.value['count'], 5);
      expect(object(store.cached(profile.id, 'taskQueueStatus'))['count'], 5);
    } finally {
      await repository.stopDownloadWork();
      await events.close();
      store.close();
      directory.deleteSync(recursive: true);
    }
  });
}
