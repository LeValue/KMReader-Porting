import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  late LocalStore store;
  late Repository repo;
  final remote = <String, dynamic>{};
  final writes = <http.Request>[];
  Completer<http.Response>? hold;
  Completer<void>? arrived;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('readlist-reading-');
    store = LocalStore(sqlite3.openInMemory());
    const profile = ServerProfile(
      id: 'list-fixture',
      name: 'Fixture',
      url: 'https://example.invalid',
      email: '',
      authentication: Authentication.apiKey,
    );
    remote.clear();
    writes.clear();
    hold = null;
    arrived = null;
    repo = Repository(
      profile: profile,
      store: store,
      directory: directory,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: profile.authentication,
        credential: '',
        client: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(jsonEncode(remote), 200);
          }
          writes.add(request);
          if (request.method == 'DELETE') {
            for (final key in jsonDecode(request.body) as List) {
              remote.remove(key);
            }
          }
          if (request.method == 'PATCH') {
            remote.addAll(Map<String, dynamic>.from(jsonDecode(request.body)));
            if (hold != null) {
              final pending = hold!;
              hold = null;
              arrived?.complete();
              return pending.future;
            }
          }
          return http.Response('', 204);
        }),
      ),
    )..setOffline(true);
    store.cache('list-fixture', 'detail:readlists:ABC123', {
      'id': 'ABC123',
      'name': 'Ordered list',
      'ordered': true,
      'bookIds': ['one', 'two', 'three'],
    });
    store.cacheItems('list-fixture', [
      for (final id in ['one', 'two', 'three'])
        CatalogItem('books', {
          'id': id,
          'libraryId': id == 'three' ? 'other' : 'main',
          'name': id,
          'metadata': {'title': id},
          'media': {'pagesCount': 10},
          'readProgress': {
            'page': id == 'one'
                ? 10
                : id == 'two'
                ? 3
                : 0,
            'completed': id == 'one',
          },
        }),
    ]);
  });
  tearDown(() {
    repo.dispose();
    store.close();
    directory.deleteSync(recursive: true);
  });
  test('ordered-list continuation follows the upstream resolver and persists stop tombstones', () async {
    await repo.readLists.record('ABC123', 'two');
    expect(repo.readLists.states, isEmpty);
    await repo.readLists.setEnabled(true);
    await repo.readLists.record('ABC123', 'two');
    expect(repo.readLists.owner('three'), 'ABC123');
    expect((await repo.readLists.continuations()).single.book.id, 'two');
    repo.markBooks([
      Book({
        'id': 'two',
        'media': {'pagesCount': 10},
      }),
    ], true);
    expect((await repo.readLists.continuations()).single.book.id, 'three');
    expect(await repo.readLists.continuations(libraryId: 'main'), isEmpty);
    await repo.readLists.stop('ABC123');
    expect(await repo.readLists.continuations(), isEmpty);
    expect(object(repo.readLists.states['ABC123'])['stopped'], true);
    remote['kmreader.readlist.abc123'] = {
      'value': jsonEncode({
        'readListId': 'ABC123',
        'bookId': 'two',
        'readAt': 1,
      }),
    };
    repo.offline = false;
    await repo.readLists.sync();
    expect(writes.single.method, 'DELETE');
    expect(repo.readLists.states, isEmpty);
    expect(remote, isEmpty);
  });
  test('old acknowledgements cannot clear a newer pending location; payload interoperates with upstream', () async {
    await repo.readLists.setEnabled(true);
    await repo.readLists.record('ABC123', 'two');
    repo.offline = false;
    final pending = Completer<http.Response>();
    hold = pending;
    arrived = Completer<void>();
    final sync = repo.readLists.sync();
    await arrived!.future;
    repo.offline = true;
    await repo.readLists.record('ABC123', 'three');
    pending.complete(http.Response('', 204));
    await sync;
    expect(object(repo.readLists.states['ABC123'])['pending'], true);
    expect(object(repo.readLists.states['ABC123'])['bookId'], 'three');
    repo.offline = false;
    await repo.readLists.sync();
    expect(object(repo.readLists.states['ABC123'])['pending'], false);
    final payload = object(
      jsonDecode(text(object(remote['kmreader.readlist.abc123'])['value'])),
    );
    expect(payload['readListId'], 'ABC123');
    expect(payload['bookId'], 'three');
    expect(payload['readAt'], isA<num>());
  });
}
