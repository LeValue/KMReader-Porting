import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/document_readers.dart';
import 'package:kmreader/features/reader/epub_document.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:sqlite3/sqlite3.dart';

const navigation = '''<html xmlns:epub="http://www.idpf.org/2007/ops"><body>
<nav epub:type="landmarks"><ol><li><a href="../one.xhtml">Wrong index</a></li></ol></nav>
<nav epub:type="toc"><ol><li><span>Part One</span><ol>
<li><a href="../one.xhtml">Start reading</a></li>
<li><a href="../two%20words.xhtml#section%20two">Hidden section</a></li>
<li><a href="https://example.invalid">External</a></li>
<li><a href="../../../outside.xhtml">Traversal</a></li>
<li><a href="../missing.xhtml">Missing</a></li>
</ol></li></ol></nav></body></html>''';

const ncxNavigation = '''<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/">
<navMap><navPoint id="part"><navLabel><text>Legacy Part</text></navLabel>
<content src="one.xhtml"/><navPoint id="section"><navLabel><text>Legacy Section</text></navLabel>
<content src="two%20words.xhtml#section%20two"/></navPoint></navPoint></navMap></ncx>''';

File createBook(Directory directory, {String? nav = navigation, String? ncx}) {
  final paragraphs = List.generate(
    70,
    (i) =>
        '<p>Paragraph $i in this synthetic chapter contains enough text to scroll.</p>',
  ).join();
  final files = {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>',
    'OPS/package.opf':
        '''<package><metadata><title>Navigation fixture</title></metadata><manifest>
<item id="one" href="one.xhtml"/><item id="two" href="two%20words.xhtml"/>
${nav == null ? '' : '<item id="nav" href="index/nav.xhtml" properties="scripted nav"/>'}
${ncx == null ? '' : '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'}
</manifest><spine toc="ncx"><itemref idref="one"/><itemref idref="two"/></spine></package>''',
    'OPS/one.xhtml':
        '<html><body><h1>Chapter One</h1><p><a href="two%20words.xhtml#section%20two">Jump to second section</a></p>$paragraphs</body></html>',
    'OPS/two words.xhtml':
        '<html><body><h1 id="top">Chapter Two</h1>$paragraphs<h2 id="section two">Target heading</h2><p><a href="#top">Return to top</a></p>$paragraphs</body></html>',
    'OPS/index/nav.xhtml': ?nav,
    'OPS/toc.ncx': ?ncx,
  };
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, utf8.encode(entry.value)));
  }
  return File('${directory.path}/navigation.epub')
    ..writeAsBytesSync(ZipEncoder().encode(archive));
}

Finder chapterText(String value) => find.descendant(
  of: find.byType(HtmlWidget),
  matching: find.text(value, findRichText: true),
);

Future<void> settleReader(WidgetTester tester, String heading) async {
  // Large chapters parse in a real isolate, outside the test's fake clock.
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (chapterText(heading).evaluate().isNotEmpty) {
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10),
      );
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  fail('EPUB content did not render: $heading');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(Strings.initialize);
  late Directory directory;
  setUp(
    () => directory = Directory.systemTemp.createTempSync('kmreader-epub-'),
  );
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'EPUB 3 uses the nested toc, preserving labels, groups and decoded targets',
    () {
      final doc = EpubDocument.open(createBook(directory).path);
      addTearDown(doc.close);
      final part = doc.tableOfContents.single;
      expect(part.title, 'Part One');
      expect(part.location, isNull);
      expect(part.children.map((e) => e.title), [
        'Start reading',
        'Hidden section',
      ]);
      expect(part.children.last.location!.path, 'OPS/two words.xhtml');
      expect(part.children.last.location!.fragment, 'section two');
      expect(doc.chapters.map((c) => c.path), [
        'OPS/one.xhtml',
        'OPS/two words.xhtml',
      ]);
    },
  );

  test('EPUB 2 NCX preserves parent destinations and nested sections', () {
    final doc = EpubDocument.open(
      createBook(directory, nav: null, ncx: ncxNavigation).path,
    );
    addTearDown(doc.close);
    final part = doc.tableOfContents.single;
    expect(part.title, 'Legacy Part');
    expect(part.location!.path, 'OPS/one.xhtml');
    expect(part.children.single.title, 'Legacy Section');
    expect(part.children.single.location!.fragment, 'section two');
  });

  test(
    'EPUB navigation recognizes namespace aliases and accessibility roles',
    () {
      for (final nav in [
        navigation
            .replaceAll('xmlns:epub', 'xmlns:ops')
            .replaceAll('epub:type', 'ops:type'),
        navigation.replaceAll('epub:type="toc"', 'role="navigation doc-toc"'),
      ]) {
        final doc = EpubDocument.open(createBook(directory, nav: nav).path);
        try {
          expect(doc.tableOfContents.single.title, 'Part One');
        } finally {
          doc.close();
        }
      }
    },
  );

  test('an unusable EPUB 3 toc falls back to NCX, then to the spine', () {
    var doc = EpubDocument.open(
      createBook(directory, nav: '<html/>', ncx: ncxNavigation).path,
    );
    expect(doc.tableOfContents.single.title, 'Legacy Part');
    doc.close();
    doc = EpubDocument.open(
      createBook(directory, nav: '<html/>', ncx: '<broken').path,
    );
    try {
      expect(doc.tableOfContents.map((e) => e.title), [
        'Chapter One',
        'Chapter Two',
      ]);
    } finally {
      doc.close();
    }
  });

  test('fragment-only paths retain their chapter and unsafe resource URLs are rejected', () {
    final location = EpubDocument.locate(
      'OPS/two words.xhtml',
      '#section%20two',
    );
    expect(location.path, 'OPS/two words.xhtml');
    expect(location.fragment, 'section two');
    expect(
      EpubDocument.resolve('OPS/one.xhtml', 'two%2520words.xhtml'),
      'OPS/two%20words.xhtml',
    );
    expect(
      EpubDocument.resolve('OPS/one.xhtml', 'two.xhtml?download=1#section'),
      'OPS/two.xhtml',
    );
    for (final path in [
      'https://example.invalid/x',
      '//example.invalid/x',
      '/etc/passwd',
      '%2e%2e/%2e%2e/etc/passwd',
      '..%5csecret',
      'x%00.xhtml',
    ]) {
      expect(
        () => EpubDocument.resolve('OPS/one.xhtml', path),
        throwsFormatException,
        reason: path,
      );
    }
  });

  for (final incognito in [false, true]) {
    testWidgets(
      'EPUB nested navigation reaches the anchor; incognito=$incognito',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final file = createBook(directory);
        final store = LocalStore(sqlite3.openInMemory());
        final manifestResponse = Completer<http.Response>();
        const profile = ServerProfile(
          id: 'epub-fixture',
          name: 'Fixture',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.password,
        );
        final repo = Repository(
          profile: profile,
          api: KomgaApi(
            Uri.parse(profile.url),
            authentication: Authentication.password,
            credential: '',
            client: MockClient((request) async {
              if (request.url.path.endsWith('/manifest')) {
                return manifestResponse.future;
              }
              if (request.url.path.endsWith('/progression')) {
                return http.Response('{}', 200);
              }
              throw StateError(
                'Unexpected network request during offline reading',
              );
            }),
          ),
          store: store,
          directory: directory,
        );
        if (incognito) repo.setOffline(true);
        final book = Book({
          'id': 'epub',
          'name': 'Navigation fixture.epub',
          'media': {'mediaType': 'application/epub+zip'},
        });
        addTearDown(() {
          repo.dispose();
          store.close();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: DocumentReader(
              repository: repo,
              book: book,
              load: () async => file,
              incognito: incognito,
            ),
          ),
        );
        if (!incognito) {
          await tester.pump();
          await tester.tap(find.byTooltip('Table of Contents'));
          await tester.pump();
          expect(
            find.byType(BottomSheet),
            findsNothing,
            reason: 'Navigation must wait until initial remote restoration has finished',
          );
          manifestResponse.complete(http.Response('{}', 200));
        }
        await settleReader(tester, 'Chapter One');
        repo.setOffline(true);
        expect(
          repo.pendingCount,
          0,
          reason: 'Opening a chapter must not send progress',
        );

        // Exercise an actual cross-chapter hyperlink, including its escaped fragment.
        await tester.tapOnText(
          find.textRange.ofSubstring('Jump to second section'),
        );
        await settleReader(tester, 'Target heading');
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('2 / 2'), findsOneWidget);
        final scrollable = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        expect(scrollable.position.pixels, greaterThan(0));
        final heading = chapterText('Target heading');
        expect(heading, findsOneWidget);
        final headingY = tester.getTopLeft(heading).dy;
        expect(
          headingY,
          inInclusiveRange(0, 800),
          reason:
              'The anchor must be visible, not just present in the widget tree',
        );
        expect(repo.pendingCount, incognito ? 0 : 1);

        final revision = repo.progressRevision;
        final fraction =
            scrollable.position.pixels / scrollable.position.maxScrollExtent;
        await tester.tap(find.byTooltip('Text Settings'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sans Serif'));
        await tester.pump();
        await tester.tapAt(const Offset(15, 90));
        await settleReader(tester, 'Target heading');
        await tester.pump(const Duration(milliseconds: 600));
        expect(
          repo.progressRevision,
          revision,
          reason: 'Changing fonts must preserve the reading location without new remote progress',
        );
        expect(
          scrollable.position.pixels / scrollable.position.maxScrollExtent,
          closeTo(fraction, 0.001),
        );

        await tester.tapOnText(find.textRange.ofSubstring('Return to top'));
        await settleReader(tester, 'Chapter Two');
        await tester.pump(const Duration(milliseconds: 600));
        expect(
          tester.getTopLeft(chapterText('Chapter Two')).dy,
          inInclusiveRange(0, 800),
        );

        await tester.tap(find.byTooltip('Table of Contents'));
        await tester.pumpAndSettle();
        expect(find.text('Part One'), findsOneWidget);
        await tester.tap(find.text('Start reading'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('1 / 2'), findsOneWidget);
        expect(scrollable.position.pixels, 0);
        expect(repo.pendingCount, incognito ? 0 : 1);
        if (!incognito) {
          final position = object(store.cached(profile.id, 'epub:epub'));
          expect(position['chapter'], 0);
          expect(position['progress'], 0);
        } else {
          expect(store.cached(profile.id, 'epub:epub'), isNull);
        }

        await tester.tap(find.byTooltip('Table of Contents'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hidden section'));
        await settleReader(tester, 'Target heading');
        expect(tester.getTopLeft(heading).dy, inInclusiveRange(0, 800));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }
}
