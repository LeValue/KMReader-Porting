import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/annotation_colors.dart';
import '../../core/models.dart';
import '../../core/page_motion.dart';
import '../../core/reader_defaults.dart';
import '../../core/repository.dart';
import 'epub_document.dart';
import 'progress_gate.dart';
import 'custom_fonts.dart';
import 'epub_host.dart';
import 'epub_page_index.dart';

class EpubAnnotationLinks {
  EpubAnnotationLinks(Iterable<Json> marks, int Function(String) chapterFor) {
    Object chapterOf(Json mark) {
      final href = text(mark['href']);
      final index = chapterFor(href);
      return index >= 0 ? index : href;
    }

    final byRange = <(Object, Object), Json>{};
    final byChapter = <Object, List<Json>>{};
    for (final mark in marks) {
      if (EpubSession.markType(mark) != 'kindle.highlight') continue;
      final chapter = chapterOf(mark);
      byRange[(chapter, EpubSession.markRange(mark))] = mark;
      (byChapter[chapter] ??= []).add(mark);
    }
    for (final note in marks) {
      if (EpubSession.markType(note) != 'kindle.note') continue;
      final chapter = chapterOf(note);
      var highlight = byRange[(chapter, EpubSession.markRange(note))];
      final start = note['kindleStart'], end = note['kindleEnd'];
      // Kindle may store a note as a point inside a separate highlight.
      if (highlight == null && start is int && (end == null || end == start)) {
        final candidates = (byChapter[chapter] ?? []).where(
          (mark) =>
              mark['kindleStart'] is int &&
              mark['kindleEnd'] is int &&
              start >= (mark['kindleStart'] as int) &&
              start < (mark['kindleEnd'] as int),
        );
        final exact = candidates.where((mark) => mark['kindleStart'] == start);
        highlight = exact.length == 1
            ? exact.single
            : candidates.length == 1
            ? candidates.single
            : null;
      }
      if (highlight != null) {
        _highlights[note['id']] = highlight;
        (_notes[highlight['id']] ??= []).add(note);
      }
    }
  }

  final _highlights = <Object?, Json>{};
  final _notes = <Object?, List<Json>>{};

  Json? highlightFor(Json note) => _highlights[note['id']];
  List<Json> notesFor(Json highlight) => _notes[highlight['id']] ?? const [];

  String colorFor(Json mark) =>
      annotationColor(highlightFor(mark)?['color']) ??
      annotationColor(mark['color']) ??
      defaultAnnotationColor;

  List<Json> relatedTo(Json mark) => switch (EpubSession.markType(mark)) {
    'kindle.note' => [?highlightFor(mark)],
    'kindle.highlight' => notesFor(mark),
    _ => const [],
  };
}

class EpubPreferences {
  const EpubPreferences({
    this.flow = 'paged',
    this.font = 'publisher',
    this.theme = 'sepia',
    this.fontSize = 19,
    this.lineHeight = 1.65,
    this.margin = 24,
    this.columns = 0,
    this.alignment = 'publisher',
    this.paragraphSpacing = .5,
    this.indent = 0,
    this.letterSpacing = 0,
    this.wordSpacing = 0,
    this.transition = 'slide',
    this.motion = const PageMotion(),
    this.tapMode = 'default',
    this.tapInversion = 'auto',
    this.animate = true,
    this.tapScroll = 80,
    this.fontWeight = 0,
    this.colorScheme = 'system',
    this.advancedLayout = true,
  });
  final String flow, font, theme, alignment, transition, tapMode, tapInversion;
  final double fontSize,
      lineHeight,
      margin,
      paragraphSpacing,
      indent,
      letterSpacing,
      wordSpacing;
  final int columns, fontWeight;
  final bool animate, advancedLayout;
  final double tapScroll;
  final String colorScheme;
  final PageMotion motion;
  factory EpubPreferences.fromJson(Json data) {
    double number(String key, double fallback, double min, double max) {
      final value = data[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    String choice(String key, List<String> values, String fallback) =>
        values.contains(data[key]) ? data[key] as String : fallback;
    return EpubPreferences(
      motion: PageMotion.fromJson(data),
      flow: choice('flow', ['paged', 'scrolled'], 'paged'),
      font: RegExp(r'^custom:[a-f0-9]{64}$').hasMatch(text(data['font']))
          ? text(data['font'])
          : choice('font', ['publisher', 'serif', 'sans-serif'], 'publisher'),
      theme: choice('theme', [
        'white',
        'sepia',
        'black',
        'system',
        'quiet',
        'green',
      ], 'sepia'),
      colorScheme: choice('colorScheme', ['system', 'light', 'dark'], 'system'),
      animate: data['animate'] != false,
      advancedLayout: data['advancedLayout'] != false,
      fontWeight: integer(data['fontWeight']).clamp(0, 1000),
      tapScroll: number('tapScroll', 80, 25, 100),
      fontSize: number('fontSize', 19, 4.75, 76),
      lineHeight: number('lineHeight', 1.65, .5, 3),
      margin: number('margin', 24, 0, 100),
      columns: [0, 1, 2].contains(data['columns'])
          ? integer(data['columns'])
          : 0,
      alignment: choice('alignment', [
        'publisher',
        'left',
        'right',
        'justify',
        'center',
      ], 'publisher'),
      paragraphSpacing: number('paragraphSpacing', .5, 0, 3),
      indent: number('indent', 0, 0, 8),
      letterSpacing: number('letterSpacing', 0, -.05, 1),
      wordSpacing: number('wordSpacing', 0, 0, 1),
      transition: choice('transition', [
        'slide',
        'cover',
        'curl',
        'none',
      ], 'slide'),
      tapMode: choice('tapMode', [
        'default',
        'none',
        'edge',
        'kindle',
        'lShape',
        'tSplit',
      ], 'default'),
      tapInversion: choice('tapInversion', [
        'auto',
        'normal',
        'inverted',
      ], 'auto'),
    );
  }
  Json toJson() => {
    'flow': flow,
    'animate': animate,
    'advancedLayout': advancedLayout,
    'fontWeight': fontWeight,
    'colorScheme': colorScheme,
    'tapScroll': tapScroll,
    'font': font,
    'theme': theme,
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'margin': margin,
    'columns': columns,
    'alignment': alignment,
    'paragraphSpacing': paragraphSpacing,
    'indent': indent,
    'letterSpacing': letterSpacing,
    'wordSpacing': wordSpacing,
    'transition': transition,
    ...motion.toJson(),
    'tapMode': tapMode,
    'tapInversion': tapInversion,
  };
}

(String, String) epubThemePalette(String theme, bool dark) => switch (theme) {
  'quiet' => dark ? ('#1E1E1E', '#BDBDBD') : ('#FAFAFA', '#111111'),
  'green' => dark ? ('#1B261B', '#D1E0D1') : ('#C7EDCC', '#1A3A1F'),
  'sepia' => dark ? ('#382E25', '#E3D5C1') : ('#F4ECD8', '#5C4A37'),
  _ => dark ? ('#000000', '#E0E0E0') : ('#FFFFFF', '#000000'),
};

class EpubSession extends ChangeNotifier {
  EpubSession._(
    this.repository,
    this.book,
    this.incognito,
    this.host,
    this.preferences,
  );
  final Repository repository;
  final Book book;
  final bool incognito;
  Json? _externalPosition;
  Json? initialKindleOffer;
  final EpubHost host;
  EpubDocument get document => host.document;
  EpubPreferences preferences;
  bool darkEnvironment = false;
  int _distance = 0;
  late final ReaderProgressGate _progressGate = ReaderProgressGate(
    book,
    repository.store.setting<int>('progressRecordingThreshold') ?? 0,
  );
  final _fontUrls = <String, String>{};
  bool get dark =>
      preferences.theme == 'black' ||
      preferences.theme != 'white' &&
          (preferences.colorScheme == 'dark' ||
              preferences.colorScheme == 'system' && darkEnvironment);
  (String, String) get themeColors => epubThemePalette(preferences.theme, dark);
  CustomFontStore get fonts =>
      CustomFontStore(repository.store, repository.directory);
  Json get browserPreferences => {
    ...preferences.toJson(),
    'spaceKeyAction':
        repository.store.setting<String>('spaceKeyAction') ?? 'toggleControls',
    'backgroundColor': themeColors.$1,
    'textColor': themeColors.$2,
    if (_fontUrls[preferences.font] case final String url) 'fontUrl': url,
  };
  Future<void> prepareFont() async {
    final selected = preferences.font;
    if (!selected.startsWith('custom:') || _fontUrls.containsKey(selected)) {
      return;
    }
    final id = selected.substring(7);
    final record = fonts.fonts.where((font) => font['id'] == id).firstOrNull;
    if (record == null) return;
    try {
      final file = fonts.file(record);
      if (await file.length() > 32 * 1024 * 1024) return;
      _fontUrls[selected] = (await host.addFont(
        id,
        await file.readAsBytes(),
      )).toString();
    } on FileSystemException {
      /* A removed font falls back to the publisher font. */
    }
  }

  String cfi = '', href = '';
  int? kindlePosition;
  int chapter = 0, page = 1, pages = 1;
  double progression = 0;
  EpubPageIndex? pageIndex;
  Future<void>? _indexing;
  double get bookProgress =>
      pageIndex?.fraction(chapter, progression) ??
      (chapter + progression) / document.chapters.length;
  int? get totalBookPages =>
      book.pages > 0 && book.media['pagesCountSource'] == 'publisher'
      ? book.pages
      : pageIndex?.pages;
  String get bookPosition => totalBookPages == null
      ? '${(bookProgress * 100).round()}%'
      : '~${(bookProgress * totalBookPages!).floor().clamp(0, totalBookPages! - 1) + 1}/$totalBookPages';
  Future<void> _index(File file) async {
    try {
      final size = await file.length();
      final key = 'epubPageIndex:${book.id}';
      final saved = object(repository.store.cached(repository.profile.id, key));
      final hash = text(book.json['fileHash']);
      final cached = saved['weights'];
      final weights =
          saved['schema'] == 2 &&
              saved['size'] == size &&
              saved['hash'] == hash &&
              cached is List &&
              cached.length == document.chapters.length &&
              cached.every((v) => v is int && v > 0)
          ? cached.cast<int>()
          : await compute(indexEpubFile, file.path);
      if (_closed ||
          repository.closed ||
          weights.length != document.chapters.length) {
        return;
      }
      pageIndex = EpubPageIndex(weights);
      repository.store.cache(repository.profile.id, key, {
        'schema': 2,
        'size': size,
        'hash': hash,
        'weights': weights,
      });
      final latest = object(
        repository.store.cached(repository.profile.id, 'book:${book.id}'),
      );
      if (book.format == 'epub' &&
          (integer(object(latest['media'])['pagesCount']) == 0 ||
              object(latest['media'])['pagesCountEstimated'] == true)) {
        repository.store.cacheBooks(repository.profile.id, [
          CatalogItem('books', {
            ...book.json,
            ...latest,
            'media': {
              ...book.media,
              ...object(latest['media']),
              'pagesCount': pageIndex!.pages,
              'pagesCountEstimated': true,
            },
          }),
        ]);
        repository.localCatalogChanged();
      }
      notifyListeners();
    } catch (_) {
      /* A missing optional index never prevents reading. */
    }
  }

  bool layoutBusy = false;
  bool ready = false,
      auxiliary = false,
      atStart = true,
      atEnd = false,
      _closed = false;
  ({int chapter, String href, String cfi, double progression})? _pending;
  void _remember() => _pending = (
    chapter: chapter,
    href: href,
    cfi: cfi,
    progression: progression,
  );
  Timer? _saveTimer;
  String get key => 'epub:${book.id}';
  String get bookmarkKey => 'epubBookmarks:${book.id}';
  List<Json> get _localAnnotations =>
      (repository.store.cached(repository.profile.id, bookmarkKey) as List? ??
              [])
          .map(object)
          .toList();
  List<Json> get bookmarks {
    if (incognito) return [];
    final local = _localAnnotations;
    final matching = {
      for (final mark in local)
        if (mark['kindlePosition'] is int)
          ('kindle.bookmark', mark['kindlePosition'], null)
        else if (mark['kindleStart'] is int && mark['kindleEnd'] is int)
          (mark['type'], mark['kindleStart'], mark['kindleEnd']),
    };
    return [
      ...local,
      for (final mark in repository.documentAnnotations(book))
        if (!matching.contains((
          mark['type'],
          mark['kindleStart'],
          mark['kindleEnd'],
        )))
          mark,
    ];
  }

  static String markType(Json mark) => text(mark['type'], 'kindle.bookmark');

  static Object markRange(Json mark) {
    if ((mark['kindleStart'] ?? mark['kindlePosition']) case final int start) {
      return (start, mark['kindleEnd']);
    }
    return mark['rangeCfi'] ?? mark['id'] ?? mark['cfi'] ?? mark;
  }

  List<Json> get readerAnnotations {
    final marks = bookmarks;
    final links = EpubAnnotationLinks(marks, chapterFor);
    return [
      for (final mark in marks)
        if (mark['rangeCfi'] != null ||
            markType(mark) != 'kindle.bookmark' && mark['locator'] is Map)
          if (links.highlightFor(mark) == null)
            if (links.notesFor(mark).firstOrNull case final Json note)
              {
                ...note,
                'rangeCfi': ?mark['rangeCfi'],
                'locator': ?mark['locator'],
                'endLocator': ?mark['endLocator'],
                'color': links.colorFor(mark),
              }
            else
              mark,
    ];
  }

  bool isCurrentBookmark(Json mark) =>
      cfi.isNotEmpty &&
      markType(mark) == 'kindle.bookmark' &&
      (mark['cfi'] == cfi ||
          kindlePosition != null &&
              (mark['kindlePosition'] ?? mark['kindleStart']) ==
                  kindlePosition);

  Json? get currentBookmark => bookmarks.where(isCurrentBookmark).firstOrNull;

  bool get hasCurrentBookmark => currentBookmark != null;

  static Future<EpubSession> open(
    Repository repository,
    Book book,
    File file, {
    bool incognito = false,
  }) async {
    // Start remote resume and ZIP inspection together; only the resource worker
    // opens the archive. The UI receives a small immutable navigation index.
    final externalPosition = incognito
        ? Future<Json?>.value()
        : repository
              .externalDocumentPosition(book, file)
              .timeout(const Duration(seconds: 4))
              .then<Json?>((value) => value, onError: (Object _) => null);
    final fetchProgress =
        !repository.profile.isKindle &&
        !repository.offline &&
        !repository.store.isPending(repository.profile.id, book.id);
    final remoteProgress = fetchProgress
        ? repository.api
              .request(
                '/api/v1/books/${Uri.encodeComponent(book.id)}/progression',
                extra: {'Accept': 'application/vnd.readium.progression+json'},
              )
              .timeout(const Duration(seconds: 4))
              .then<Json?>((v) => object(v), onError: (Object _) => null)
        : Future<Json?>.value();
    EpubHost? host;
    try {
      host = await EpubHost.openFile(file.path);
      final doc = host.document;
      final saved = object(
        repository.store.cached(repository.profile.id, 'epub:${book.id}'),
      );
      if (repository.store.setting<bool>('epubVolumeCounterMigrated') != true) {
        final overlay = object(
          repository.store.setting<dynamic>('epubOverlay'),
        );
        if (overlay['controlsFooterCenter'] == 'chapterPosition') {
          repository.store.setSetting('epubOverlay', {
            ...overlay,
            'controlsFooterCenter': 'bookPosition',
          });
        }
        repository.store.setSetting('epubVolumeCounterMigrated', true);
      }
      final session = EpubSession._(
        repository,
        book,
        incognito,
        host,
        EpubPreferences.fromJson({
          if (saved.containsKey('chapter') &&
              saved['readerFlowVersion'] == null)
            'flow': 'scrolled',
          ...object(repository.store.setting<dynamic>('epubDefault')),
          ...saved,
        }),
      );
      session.chapter = integer(saved['chapter'])
          .clamp(0, doc.chapters.length - 1);
      session.href = doc.chapters[session.chapter].path;
      session.cfi = text(saved['cfi']);
      session.progression =
          (saved['progress'] is num
                  ? (saved['progress'] as num).toDouble()
                  : 0.0)
              .clamp(0, 1);
      if (fetchProgress) {
        try {
          final remote = await remoteProgress ?? <String, dynamic>{};
          final modified = DateTime.tryParse(text(remote['modified']));
          final local = DateTime.tryParse(text(saved['modified']));
          if (saved.isEmpty ||
              modified != null && (local == null || modified.isAfter(local))) {
            final locator = object(remote['locator']);
            final index = session.chapterFor(text(locator['href']));
            if (index >= 0) {
              session.chapter = index;
              session.href = doc.chapters[index].path;
              final locations = object(locator['locations']);
              session.progression =
                  ((locations['progression'] as num?)?.toDouble() ?? 0).clamp(
                    0,
                    1,
                  );
              session.cfi =
                  (locations['fragments'] as List? ?? [])
                      .whereType<String>()
                      .where((s) => s.startsWith('epubcfi('))
                      .firstOrNull ??
                  '';
            }
          }
        } catch (_) {
          /* Offline/local resume remains usable. */
        }
      }
      if (book.completed) {
        session.chapter = 0;
        session.href = doc.chapters.first.path;
        session.cfi = '';
        session.progression = 0;
      }
      final external = await externalPosition;
      if (external != null && session.chapterFor(text(external['href'])) >= 0) {
        if (external['acceptedConflict'] == true) {
          session._externalPosition = external;
        } else {
          session.initialKindleOffer = external;
        }
      }
      // This locator belongs to a replacement whose reading state the user
      // already opted to restore. It is the local bookmark for the new edition.
      final migrated = object(saved['kindleResume']);
      if (session._externalPosition == null &&
          session.chapterFor(text(migrated['href'])) >= 0 &&
          migrated.isNotEmpty) {
        session._externalPosition = migrated;
      }
      await session.prepareFont();
      session._indexing = session._index(file);
      unawaited(session._indexing);
      return session;
    } catch (_) {
      await host?.close();
      host?.document.close();
      rethrow;
    }
  }

  int chapterFor(String href) {
    final uri = Uri.tryParse(href);
    if (uri == null) return -1;
    final path = Uri.decodeComponent(uri.path);
    return document.chapters.indexWhere(
      (c) =>
          c.path == path ||
          c.path.endsWith('/$path') ||
          path.endsWith('/${c.path}'),
    );
  }

  String relativeHref(String path, {String fragment = ''}) => Uri(
    path: p.posix.relative(path, from: p.posix.dirname(host.packagePath)),
    fragment: fragment.isEmpty ? null : fragment,
  ).toString();

  Json configuration(String nonce) => {
    'url': host.publication.toString(),
    'nonce': nonce,
    'preferences': browserPreferences,
    'direction': host.direction == 'rtl' ? 'rtl' : 'ltr',
    'language': host.language,
    if (cfi.isNotEmpty) 'cfi': cfi,
    'href': relativeHref(href),
    'progression': progression,
    if (repository.profile.isKindle && !incognito) 'kindlePositions': true,
    if (_externalPosition case final locator?)
      'kindleResume': kindleTarget(locator),
    'annotations': readerAnnotations,
  };

  Json kindleTarget(Json locator) => {
    ...locator,
    'href': relativeHref(
      document.chapters[chapterFor(text(locator['href']))].path,
    ),
  };

  void rememberKindleResume(Json locator, {bool fromCloud = true}) {
    if (_closed || incognito || repository.closed || cfi.isEmpty) return;
    _externalPosition = null;
    _pending = null;
    _saveTimer?.cancel();
    final store = repository.store;
    final account = repository.profile.id;
    final legacyPosition = object(store.cached(account, key))
        .containsKey('chapter');
    repository.store.transaction(() {
      writeReaderVolumePreferences(
        store,
        account,
        key,
        {
          if (!legacyPosition) 'readerFlowVersion': 1,
          'chapter': chapter,
          'progress': progression,
          'cfi': cfi,
          'modified':
              locator['modified'] ?? DateTime.now().toUtc().toIso8601String(),
        },
        reset: const ['kindleResume', 'kindleResumeChoice'],
      );
      if (fromCloud) {
        repository.externalDocumentPositionApplied(book, locator);
        repository.setEpubProgress(
          book,
          href,
          progression,
          bookProgress,
          cfi: cfi,
          fromServer: true,
        );
      }
    });
  }

  void keepKindlePosition(Json offer) {
    if (_closed || incognito || repository.closed || cfi.isEmpty) return;
    rememberKindleResume({}, fromCloud: false);
    repository.keepDocumentPosition(book, offer, kindlePosition);
  }

  void receive(Json event) {
    if (_closed) return;
    final before = (
      layoutBusy,
      ready,
      auxiliary,
      chapter,
      page,
      pages,
      atStart,
      atEnd,
      cfi,
      href,
      progression,
    );
    switch (event['type']) {
      case 'layout':
        layoutBusy = event['active'] == true;
      case 'ready':
        ready = true;
        final external = _externalPosition;
        _externalPosition = null;
        if (event['kindleResumeApplied'] == true && external != null) {
          rememberKindleResume(
            external,
            fromCloud: external['acceptedConflict'] == true,
          );
        }
      case 'auxiliary':
        auxiliary = event['active'] == true;
      case 'position':
        if (auxiliary) return;
        final index = chapterFor(text(event['href']));
        final value = event['progression'];
        if (index < 0 || value is! num || !value.isFinite) return;
        if (event['changed'] == true) {
          _distance += index == chapter
              ? integer(event['page'], 1) - page
              : index > chapter
              ? 1
              : -1;
        }
        chapter = index;
        href = document.chapters[index].path;
        cfi = text(event['cfi']);
        final original = event['kindlePosition'];
        kindlePosition =
            original is num &&
                original.isFinite &&
                original == original.roundToDouble()
            ? original.toInt()
            : null;
        progression = value.toDouble().clamp(0, 1);
        page = integer(event['page'], 1).clamp(1, 1 << 20);
        pages = integer(event['pages'], 1).clamp(1, 1 << 20);
        atStart = event['atStart'] == true;
        atEnd = event['atEnd'] == true;
        if (event['changed'] == true) {
          _externalPosition = null;
          if (!incognito) repository.documentPosition(book, event);
          _remember();
          _saveTimer?.cancel();
          _saveTimer = Timer(const Duration(milliseconds: 400), save);
        }
      case 'end':
        if (!auxiliary && atEnd) {
          progression = 1;
          _remember();
          save();
        }
      default:
        return;
    }
    if (before !=
        (
          layoutBusy,
          ready,
          auxiliary,
          chapter,
          page,
          pages,
          atStart,
          atEnd,
          cfi,
          href,
          progression,
        )) {
      notifyListeners();
    }
  }

  void setPreferences(EpubPreferences value, {bool persist = true}) {
    final changes = readerPreferenceChanges(
      preferences.toJson(),
      value.toJson(),
    );
    preferences = value;
    if (persist && !repository.closed && changes.isNotEmpty) {
      writeReaderVolumePreferences(
        repository.store,
        repository.profile.id,
        key,
        changes,
      );
    }
    notifyListeners();
  }

  EpubPreferences resetPreferences() {
    final store = repository.store;
    writeReaderVolumePreferences(store, repository.profile.id, key, {
      'readerFlowVersion': 1,
    }, reset: preferences.toJson().keys);
    return EpubPreferences.fromJson(
      object(store.setting<dynamic>('epubDefault')),
    );
  }

  void save() {
    _saveTimer?.cancel();
    final pending = _pending;
    if (pending == null || incognito || _closed || repository.closed) return;
    if (!_progressGate.allows(
      page,
      distance: _distance.abs(),
      completed: atEnd,
    )) {
      return;
    }
    final store = repository.store;
    final account = repository.profile.id;
    final legacyPosition = object(store.cached(account, key))
        .containsKey('chapter');
    writeReaderVolumePreferences(
      store,
      account,
      key,
      {
        if (!legacyPosition) 'readerFlowVersion': 1,
        'chapter': pending.chapter,
        'progress': pending.progression,
        'cfi': pending.cfi,
        'modified': DateTime.now().toUtc().toIso8601String(),
      },
      reset: const ['kindleResume', 'kindleResumeChoice'],
    );
    repository.setEpubProgress(
      book,
      pending.href,
      pending.progression,
      pageIndex?.fraction(pending.chapter, pending.progression) ??
          (pending.chapter + pending.progression) / document.chapters.length,
      cfi: pending.cfi,
    );
    _pending = null;
  }

  void toggleBookmark(String label) {
    if (cfi.isEmpty || incognito || repository.closed) return;
    if (currentBookmark case final Json bookmark) {
      removeAnnotation(bookmark);
      return;
    }
    final values = _localAnnotations;
    repository.store.transaction(() {
      final position = kindlePosition;
      _writeAnnotations([
        ...values,
        {
          'cfi': cfi,
          'href': href,
          'label': label.trim().isEmpty
              ? document.chapters[chapter].title
              : label,
          'created': DateTime.now().toUtc().toIso8601String(),
          'kindlePosition': ?position,
        },
      ]);
      if (position != null) {
        repository.documentBookmark(book, position, present: true);
      }
    });
    notifyListeners();
  }

  bool saveAnnotation(Json selection, {String? note, String? color}) {
    if (incognito || repository.closed) return false;
    final start = text(selection['cfi']), range = text(selection['rangeCfi']);
    final index = chapterFor(text(selection['href']));
    if (index < 0 ||
        !start.startsWith('epubcfi(') ||
        !range.startsWith('epubcfi(') ||
        start.length > 4096 ||
        range.length > 4096) {
      return false;
    }
    final excerpt = String.fromCharCodes(
      text(selection['text']).trim().runes.take(750),
    );
    final body = note?.trim();
    if (excerpt.isEmpty || body?.isEmpty == true) return false;
    final type = body == null ? 'kindle.highlight' : 'kindle.note';
    final values = _localAnnotations;
    final id = '$type:$range';
    values.removeWhere((mark) => mark['id'] == id);
    final startPosition = selection['kindleStart'],
        endPosition = selection['kindleEnd'];
    final mark = {
      'id': id,
      'type': type,
      'cfi': start,
      'rangeCfi': range,
      'href': document.chapters[index].path,
      'label': body ?? excerpt,
      'excerpt': excerpt,
      'color': ?annotationColor(color ?? selection['color']),
      'created': DateTime.now().toUtc().toIso8601String(),
      if (startPosition is int &&
          endPosition is int &&
          endPosition > startPosition) ...{
        'kindleStart': startPosition,
        'kindleEnd': endPosition,
      },
    };
    repository.store.transaction(() {
      final highlight = {
        ...mark,
        'id': 'kindle.highlight:$range',
        'type': 'kindle.highlight',
        'label': excerpt,
      };
      final addInk =
          body != null &&
          !bookmarks.any(
            (value) =>
                markType(value) == 'kindle.highlight' &&
                (markRange(value) == markRange(mark) ||
                    value['rangeCfi'] == range),
          );
      _writeAnnotations([...values, if (addInk) highlight, mark]);
      if (addInk) repository.documentAnnotation(book, highlight, present: true);
      repository.documentAnnotation(book, mark, present: true);
    });
    notifyListeners();
    return true;
  }

  bool canRemoveAnnotation(Json mark) =>
      !incognito &&
      !repository.closed &&
      (mark['source'] != 'kindle' ||
          repository.canDeleteDocumentAnnotation(book, mark));

  void removeAnnotation(Json mark) {
    if (!canRemoveAnnotation(mark)) return;
    final related = [
      mark,
      ...EpubAnnotationLinks(
        bookmarks,
        chapterFor,
      ).relatedTo(mark).where(canRemoveAnnotation),
    ];
    repository.store.transaction(() {
      final values = _localAnnotations
        ..removeWhere(
          (value) => related.any(
            (remove) => remove['id'] != null
                ? value['id'] == remove['id'] ||
                      markType(value) == markType(remove) &&
                          markRange(value) == markRange(remove)
                : value['id'] == null && value['cfi'] == remove['cfi'],
          ),
        );
      _writeAnnotations(values);
      for (final removed in related) {
        if (removed['kindlePosition'] case final int position) {
          repository.documentBookmark(book, position, present: false);
        } else {
          repository.documentAnnotation(book, removed, present: false);
        }
      }
    });
    notifyListeners();
  }

  void _writeAnnotations(List<Json> values) =>
      repository.store.cache(repository.profile.id, bookmarkKey, values);

  Future<void> close() async {
    if (_closed) return;
    save();
    _closed = true;
    _saveTimer?.cancel();
    await _indexing;
    await host.close();
    document.close();
    dispose();
  }
}
