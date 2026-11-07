import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/kindle/catalog_filter.dart';
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/conversion.dart';
import 'package:kmreader/core/kindle/library.dart';
import 'package:kmreader/core/kindle/repository.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'dictionary flags, purchased dictionaries and legacy titles are hidden',
    () {
      for (final item in <Json>[
        {'is_dictionary': true},
        {'isDictionary': 'true'},
        {'is_amazon_dictionary': 1},
        {
          'content_tags': ['DICT'],
        },
        {'classification': 'DICTIONARY'},
        {
          'title': 'The New Oxford American Dictionary',
          'is_amazon_dictionary': false,
        },
        {'title': 'Groot woordenboek Frans-Nederlands'},
        {'title': 'Oxford Arabic Dictionary'},
      ]) {
        expect(isKindleDictionary(item), isTrue, reason: '$item');
      }
      for (final title in [
        'The Dictionary of Lost Words',
        'Il mio dizionario',
        'Oxford Summer',
        'Hyperion',
      ]) {
        expect(isKindleDictionary({'title': title}), isFalse, reason: title);
      }
    },
  );

  late LocalStore store;
  late Directory directory;
  late KindleRepository repo;
  const profile = ServerProfile(
    id: 'large',
    name: 'Kindle',
    url: 'https://www.amazon.it',
    email: '',
    authentication: Authentication.apiKey,
    source: 'kindle',
  );
  setUp(() {
    store = LocalStore(sqlite3.openInMemory());
    directory = Directory.systemTemp.createTempSync('kindle-index-');
    repo = KindleRepository(
      profile: profile,
      store: store,
      directory: directory,
      client: KindleClient(
        client: MockClient((_) async => http.Response('', 500)),
      ),
    )..setOffline(true);
  });
  tearDown(() async {
    await repo.stopDownloadWork();
    store.close();
    directory.deleteSync(recursive: true);
  });

  test('first offline catalog removes old dictionary rows and preserves progress and files', () async {
    final dictionary = {
      'key': 'EBOK:dict',
      'title': 'The New Oxford American Dictionary',
      'type': 'EBOK',
    };
    final id = repo.library.idFor(dictionary);
    store.cache(profile.id, 'kindle:catalog', {
      'items': [
        dictionary,
        {'key': 'PDOC:novel', 'title': 'Hyperion'},
      ],
    });
    store.cacheBooks(profile.id, [
      CatalogItem('books', {
        'id': id,
        'metadata': {'title': dictionary['title']},
      }),
    ]);
    store.recordProgress(profile.id, id, {'page': 8});
    final saved = File('${directory.path}/retained.epub')
      ..writeAsStringSync('saved');
    final result = await repo.catalog('books');
    expect(result.items.map((e) => e.book.title), ['Hyperion']);
    expect(store.cached(profile.id, 'book:$id'), isNull);
    expect(store.progress(profile.id, id)?['page'], 8);
    expect(saved.readAsStringSync(), 'saved');
    await expectLater(repo.book(id), throwsA(isA<KindleFailure>()));
  });

  test(
    'large cached catalog yields to UI events before indexing completes',
    () async {
      store.cache(profile.id, 'kindle:catalog', {
        'items': [
          for (var i = 0; i < 2400; i++)
            {'key': 'PDOC:$i', 'title': 'Document $i', 'type': 'PDOC'},
        ],
      });
      var events = 0, completed = false;
      final pulse = Timer.periodic(const Duration(milliseconds: 1), (_) {
        if (!completed) events++;
      });
      try {
        final result = await repo.catalog('books');
        completed = true;
        expect(result.total, 2400);
        expect(
          events,
          greaterThan(3),
          reason: 'Catalog initialization must let queued UI events run',
        );
      } finally {
        pulse.cancel();
      }
    },
  );

  test(
    'cover fan-out is bounded and closing an account cancels queued covers',
    () async {
      final preparation = _Covers();
      final client = _CoverClient();
      final library = KindleLibrary(
        client: client,
        store: store,
        directory: directory,
        profile: profile,
        preparation: preparation,
      );
      addTearDown(() {
        library.close();
        client.close();
      });
      store.setSetting('offline:${profile.id}', false);
      store.cache(profile.id, 'kindle:catalog', {
        'items': [
          for (var i = 0; i < 9; i++)
            {'key': 'PDOC:$i', 'title': 'Document $i'},
        ],
      });
      await library.initialize();
      final covers = [
        for (final item in library.items) library.cover(library.idFor(item)),
      ];
      await preparation.third.future.timeout(const Duration(seconds: 5));
      expect(preparation.calls, 3);
      library.close();
      preparation.release.complete();
      expect(await Future.wait(covers), everyElement(isNull));
      expect(
        preparation.calls,
        3,
        reason: 'Queued covers must not start after the account closes',
      );
    },
  );

  test(
    'closing during initialization settles before the store can be disposed',
    () async {
      store.cacheEncoded(
        profile.id,
        'kindle:catalog',
        jsonEncode({
          'items': [
            for (var i = 0; i < 2000; i++)
              {'key': 'PDOC:$i', 'title': 'Document $i'},
          ],
        }),
      );
      final initializing = repo.library.initialize();
      await repo.stopDownloadWork();
      await initializing;
      expect(store.setting<String>('kindleIndex:${profile.id}'), isNull);
    },
  );
}

class _Covers implements KindlePreparation, KindleCoverPreparation {
  final third = Completer<void>(), release = Completer<void>();
  int calls = 0;
  @override
  Future<Json> cover(List<String> urls) async {
    if (++calls == 3) third.complete();
    await release.future;
    return {};
  }

  @override
  Future<Json> prepare(Directory directory, {Future<void>? abortTrigger}) =>
      throw UnimplementedError();
}

class _CoverClient extends KindleClient {
  @override
  Future<(Json, Map<String, String>)> manifest(Json item) async =>
      (<String, dynamic>{'resources': []}, <String, String>{});
}
