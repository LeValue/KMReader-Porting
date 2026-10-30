import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/epub_document.dart';
import 'package:kmreader/features/reader/epub_host.dart';
import 'package:kmreader/features/reader/epub_session.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/epub_fixture.dart';

void main() {
  // Capture the real transport before widget-test HTTP overrides are installed.
  final client = HttpClient();
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDownAll(client.close);
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('epub-browser-'));
  tearDown(() => directory.deleteSync(recursive: true));
  test('publication host serves only token-scoped archive resources', () async {
    final document = EpubDocument.open(fixture(directory).path);
    final host = await EpubHost.open(
      document,
      filePath: '${directory.path}/browser.epub',
    );
    addTearDown(() async {
      await host.close();
      document.close();
    });
    final request = await client.getUrl(host.publication);
    final response = await request.close();
    expect(response.statusCode, 200);
    expect(
      await utf8.decoder.bind(response).join(),
      contains('Browser fixture'),
    );
    expect(
      response.headers.value('Content-Security-Policy'),
      contains("connect-src 'self'"),
    );
    for (final suffix in [
      '../book/OPS/one.xhtml',
      'book/../../outside',
      'book/unknown.xhtml',
    ]) {
      final denied = await (await client.getUrl(host.base.resolve(suffix)))
          .close();
      expect(denied.statusCode, 404);
      await denied.drain<void>();
    }
    final bootstrap = await (await client.getUrl(host.reader)).close();
    expect(await utf8.decoder.bind(bootstrap).join(), contains('epub.min.js'));
  });
  test('browser session persists user CFI navigation but excludes reflow and incognito', () async {
    final store = LocalStore(sqlite3.openInMemory());
    const profile = ServerProfile(
      id: 'browser',
      name: 'Fixture',
      url: 'https://example.invalid',
      email: '',
      authentication: Authentication.apiKey,
    );
    final repository = Repository(
      profile: profile,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: profile.authentication,
        credential: '',
      ),
      store: store,
      directory: directory,
    )..setOffline(true);
    final book = Book({
      'id': 'browser',
      'name': 'browser.epub',
      'media': {'mediaProfile': 'EPUB'},
    });
    final session = await EpubSession.open(
      repository,
      book,
      fixture(directory),
    );
    session.receive({
      'type': 'position',
      'href': 'one.xhtml',
      'cfi': 'epubcfi(/6/2!/4/2)',
      'page': 2,
      'pages': 20,
      'progression': .1,
      'changed': false,
    });
    session.save();
    expect(repository.pendingCount, 0);
    session.receive({
      'type': 'position',
      'href': 'one.xhtml',
      'cfi': 'epubcfi(/6/2!/4/8)',
      'page': 3,
      'pages': 20,
      'progression': .2,
      'changed': true,
    });
    session.receive({
      'type': 'position',
      'href': 'one.xhtml',
      'cfi': 'reflow-only',
      'progression': .18,
      'changed': false,
    });
    session.save();
    expect(repository.pendingCount, 1);
    final saved = object(store.cached(profile.id, session.key));
    expect(saved['cfi'], 'epubcfi(/6/2!/4/8)');
    expect(
      object(
        object(store.progress(profile.id, book.id)!['progression'])['locator'],
      )['locations'],
      containsPair('fragments', ['epubcfi(/6/2!/4/8)']),
    );
    session.setPreferences(
      EpubPreferences.fromJson({
        ...session.preferences.toJson(),
        'fontSize': 26,
      }),
    );
    expect(object(store.cached(profile.id, session.key))['cfi'], saved['cfi']);
    await session.close();
    final private = await EpubSession.open(
      repository,
      book,
      fixture(directory),
      incognito: true,
    );
    private.receive({
      'type': 'position',
      'href': 'two.xhtml',
      'cfi': 'private',
      'progression': .9,
      'changed': true,
    });
    await private.close();
    expect(object(store.cached(profile.id, session.key))['cfi'], saved['cfi']);
    repository.dispose();
    store.close();
  });
  for (final width in [390, 411, 1044]) {
    for (final flow in ['paged', 'scrolled']) {
      test(
        'vertical CJK EPUB $flow flow preserves navigation at $width pixels',
        () async {
          final file = verticalEpubFixture(directory);
          final doc = EpubDocument.open(file.path);
          final host = await EpubHost.open(doc, filePath: file.path);
          try {
            final result = await Process.run('python3', [
              'tool/epub_layout_smoke.py',
              host.reader.toString(),
              jsonEncode({
                'url': host.publication.toString(),
                'preferences': EpubPreferences.fromJson({'flow': flow})
                    .toJson(),
                'nonce': 'vertical',
                'direction': 'rtl',
                'language': 'ja',
                'kind': 'vertical',
                'viewport': {
                  'width': width,
                  'height': width == 1044
                      ? 720
                      : width == 411
                      ? 700
                      : 780,
                },
                'href': 'one.xhtml',
              }),
            ]);
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout}\n${result.stderr}',
            );
          } finally {
            await host.close();
            doc.close();
          }
        },
        skip: Platform.environment['KMREADER_BROWSER_TEST'] != '1',
      );
    }
  }
  for (final flow in ['paged', 'scrolled']) {
    test(
      'fixed-layout EPUB $flow flow preserves authored typography and navigation',
      () async {
        final file = fixedLayoutFixture(directory);
        final doc = EpubDocument.open(file.path);
        final host = await EpubHost.open(doc, filePath: file.path);
        try {
          final result = await Process.run('python3', [
            'tool/epub_layout_smoke.py',
            host.reader.toString(),
            jsonEncode({
              'url': host.publication.toString(),
              'preferences': EpubPreferences.fromJson({'flow': flow}).toJson(),
              'nonce': 'fixed-layout',
              'direction': 'ltr',
              'href': 'one.xhtml',
            }),
          ]);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
        } finally {
          await host.close();
          doc.close();
        }
      },
      skip: Platform.environment['KMREADER_BROWSER_TEST'] != '1',
    );
  }
  for (final width in [390, 1044]) {
    test(
      'long default EPUB serializes rapid navigation and keeps visible text at $width pixels',
      () async {
        final file = fixture(directory, paragraphCount: 1400);
        final document = EpubDocument.open(file.path);
        final host = await EpubHost.open(document, filePath: file.path);
        try {
          final result = await Process.run('python3', [
            'tool/epub_performance_smoke.py',
            host.reader.toString(),
            jsonEncode({
              'url': host.publication.toString(),
              'preferences': const EpubPreferences().toJson(),
              'nonce': 'performance',
              'direction': 'ltr',
              'href': 'one.xhtml',
              'viewport': {'width': width, 'height': width == 390 ? 780 : 720},
            }),
          ]);
          // ignore: avoid_print
          print(result.stdout);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
        } finally {
          await host.close();
          document.close();
        }
      },
      skip: Platform.environment['KMREADER_BROWSER_TEST'] != '1',
    );
  }
  test('shipped browser engine paginates, reflows, searches and restores footnotes', () async {
    final doc = EpubDocument.open(fixture(directory).path);
    final host = await EpubHost.open(
      doc,
      filePath: '${directory.path}/browser.epub',
    );
    try {
      final result = await Process.run('python3', [
        'tool/epub_browser_smoke.py',
        host.reader.toString(),
        jsonEncode({
          'url': host.publication.toString(),
          'preferences': const EpubPreferences().toJson(),
          'nonce': 'fixture',
          'direction': 'ltr',
          'href': 'one.xhtml',
          'footnote': host.base.resolve('book/OPS/notes.xhtml#note').toString(),
        }),
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    } finally {
      await host.close();
      doc.close();
    }
  }, skip: Platform.environment['KMREADER_BROWSER_TEST'] != '1');
}
