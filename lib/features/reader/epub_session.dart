import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/models.dart';
import '../../core/repository.dart';
import 'epub_document.dart';
import 'progress_gate.dart';
import 'custom_fonts.dart';
import 'epub_host.dart';

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
      fontWeight: integer(data['fontWeight']).clamp(0, 900),
      tapScroll: number('tapScroll', 80, 25, 100),
      fontSize: number('fontSize', 19, 8, 60),
      lineHeight: number('lineHeight', 1.65, 1, 3),
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
      indent: number('indent', 0, 0, 4),
      letterSpacing: number('letterSpacing', 0, -.05, .3),
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
    'tapMode': tapMode,
    'tapInversion': tapInversion,
  };
}

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
  (String, String) get themeColors => switch (preferences.theme) {
    'quiet' => dark ? ('#1E1E1E', '#BDBDBD') : ('#FAFAFA', '#111111'),
    'green' => dark ? ('#1B261B', '#D1E0D1') : ('#C7EDCC', '#1A3A1F'),
    'sepia' => dark ? ('#382E25', '#E3D5C1') : ('#F4ECD8', '#5C4A37'),
    _ => dark ? ('#000000', '#E0E0E0') : ('#FFFFFF', '#000000'),
  };
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
  int chapter = 0, page = 1, pages = 1;
  double progression = 0;
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
  List<Json> get bookmarks =>
      (repository.store.cached(repository.profile.id, bookmarkKey) as List? ??
              [])
          .map(object)
          .toList();

  static Future<EpubSession> open(
    Repository repository,
    Book book,
    File file, {
    bool incognito = false,
  }) async {
    final doc = await EpubDocument.openAsync(file.path);
    EpubHost? host;
    try {
      host = await EpubHost.open(doc, filePath: file.path);
      final saved = object(
        repository.store.cached(repository.profile.id, 'epub:${book.id}'),
      );
      final session = EpubSession._(
        repository,
        book,
        incognito,
        host,
        EpubPreferences.fromJson({
          ...object(repository.store.setting<dynamic>('epubDefault')),
          if (saved.isNotEmpty && !saved.containsKey('flow'))
            'flow': 'scrolled',
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
      if (!repository.offline &&
          !repository.store.isPending(repository.profile.id, book.id)) {
        try {
          final remote = object(
            await repository.api
                .request(
                  '/api/v1/books/${Uri.encodeComponent(book.id)}/progression',
                  extra: {'Accept': 'application/vnd.readium.progression+json'},
                )
                .timeout(const Duration(seconds: 4)),
          );
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
      await session.prepareFont();
      return session;
    } catch (_) {
      await host?.close();
      doc.close();
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
  };

  void receive(Json event) {
    if (_closed) return;
    switch (event['type']) {
      case 'ready':
        ready = true;
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
        progression = value.toDouble().clamp(0, 1);
        page = integer(event['page'], 1).clamp(1, 1 << 20);
        pages = integer(event['pages'], 1).clamp(1, 1 << 20);
        atStart = event['atStart'] == true;
        atEnd = event['atEnd'] == true;
        if (event['changed'] == true) {
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
    }
    notifyListeners();
  }

  void setPreferences(EpubPreferences value) {
    preferences = value;
    if (!repository.closed) {
      final old = object(repository.store.cached(repository.profile.id, key));
      repository.store.cache(repository.profile.id, key, {
        ...old,
        ...value.toJson(),
      });
    }
    notifyListeners();
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
    final old = object(repository.store.cached(repository.profile.id, key));
    repository.store.cache(repository.profile.id, key, {
      ...old,
      ...preferences.toJson(),
      'chapter': pending.chapter,
      'progress': pending.progression,
      'cfi': pending.cfi,
      'modified': DateTime.now().toUtc().toIso8601String(),
    });
    repository.setEpubProgress(
      book,
      pending.href,
      pending.progression,
      (pending.chapter + pending.progression) / document.chapters.length,
      cfi: pending.cfi,
    );
    _pending = null;
  }

  void toggleBookmark(String label) {
    if (cfi.isEmpty || repository.closed) return;
    final values = bookmarks;
    final index = values.indexWhere((v) => v['cfi'] == cfi);
    if (index >= 0) {
      values.removeAt(index);
    } else {
      values.add({
        'cfi': cfi,
        'href': href,
        'label': label.trim().isEmpty
            ? document.chapters[chapter].title
            : label,
        'created': DateTime.now().toUtc().toIso8601String(),
      });
    }
    repository.store.cache(repository.profile.id, bookmarkKey, values);
    notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    save();
    _closed = true;
    _saveTimer?.cancel();
    await host.close();
    document.close();
    dispose();
  }
}
