import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../features/reader/raster_pages.dart';
import '../features/reader/epub_document.dart';
import 'api.dart';
import 'cache.dart';
import 'models.dart';
import 'repository.dart';

/// Owned copies, independent of accounts, downloads and the server outbox.
class LocalLibrary extends Repository {
  LocalLibrary({required super.store, required super.directory})
    : super(
        profile: const ServerProfile(
          id: scope,
          name: 'Local Books',
          url: 'https://local.invalid',
          email: '',
          authentication: Authentication.password,
        ),
        api: KomgaApi(
          Uri.parse('https://local.invalid'),
          authentication: Authentication.password,
          credential: '',
        ),
      ) {
    store.db.execute(
      'CREATE TABLE IF NOT EXISTS local_books(id TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    setOffline(true);
  }
  @override
  bool get offlineMetadataComplete => true;
  static const scope = 'device-library';
  Directory get root => Directory(p.join(directory.path, scope, 'originals'));
  List<Book> get books => store.db
      .select('SELECT value FROM local_books ORDER BY rowid DESC')
      .map((row) => overlay(Book(object(jsonDecode(row['value'] as String)))))
      .toList();
  @override
  File bookFile(Book book) => File(p.join(root.path, book.id));
  @override
  void setProgress(Book book, int page, {bool? completed, bool reset = false}) {
    if (book.pages > 0) {
      final rows = store.db.select('SELECT value FROM local_books WHERE id=?', [
        book.id,
      ]);
      if (rows.isNotEmpty) {
        final original = Book(
          object(jsonDecode(rows.first['value'] as String)),
        );
        if (original.pages != book.pages) {
          store.db.execute('UPDATE local_books SET value=? WHERE id=?', [
            jsonEncode({
              ...original.json,
              'media': {...original.media, 'pagesCount': book.pages},
            }),
            book.id,
          ]);
        }
      }
    }
    super.setProgress(book, page, completed: completed, reset: reset);
  }

  @override
  Future<void> sync({bool force = false}) async {
    // Progress is already durable in SQLite. It never belongs to a Komga queue.
    for (final row in store.pending(scope)) {
      store.acknowledge(scope, row['book'] as String, row['revision'] as int);
    }
  }

  @override
  Future<dynamic> get(
    String path, {
    String method = 'GET',
    dynamic body,
    Map<String, dynamic>? query,
    bool cacheFirst = false,
    bool force = false,
    String? cacheKey,
  }) async {
    if (path.endsWith('/pages')) return <Json>[];
    return <String, dynamic>{};
  }

  @override
  Future<Book> book(String id, {bool force = false}) async =>
      books.firstWhere((b) => b.id == id);

  Future<void> _imports = Future.value();
  Future<Book> importFile(XFile source) {
    final work = _imports.then((_) => _importFile(source));
    _imports = work.then<void>((_) {}, onError: (Object _) {});
    return work;
  }

  Future<Book> _importFile(XFile source) async {
    final extension = p.extension(source.name).toLowerCase();
    if (!['.epub', '.pdf', '.cbz', '.zip'].contains(extension)) {
      throw const FormatException('Supported files: EPUB, PDF, CBZ, ZIP.');
    }
    await root.create(recursive: true);
    final temporary = File(
      p.join(root.path, '.import-${DateTime.now().microsecondsSinceEpoch}'),
    );
    try {
      final sink = temporary.openWrite();
      try {
        await sink.addStream(source.openRead());
      } finally {
        await sink.close();
      }
      final digest = await sha256.bind(temporary.openRead()).first;
      final id = digest.toString();
      final existing = books.where((book) => book.id == id).firstOrNull;
      if (existing != null) return existing;
      final info = await Isolate.run(
        () => _inspectLocal(temporary.path, extension),
      );
      final book = Book({
        'id': id,
        'name': source.name,
        'metadata': {
          'title': text(info['title'], p.basenameWithoutExtension(source.name)),
        },
        'media': {'mediaProfile': info['profile'], 'pagesCount': info['count']},
      });
      await temporary.rename(bookFile(book).path);
      store.db.execute('INSERT INTO local_books(id,value) VALUES(?,?)', [
        id,
        jsonEncode(book.json),
      ]);
      changed();
      return book;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> remove(Book book) async {
    // Only the content-addressed copy owned by this library is removed.
    final file = bookFile(book);
    if (await file.exists()) await file.delete();
    store.db.execute('DELETE FROM local_books WHERE id=?', [book.id]);
    changed();
  }
}

Json _inspectLocal(String file, String extension) {
  final input = InputFileStream(file);
  try {
    if (extension == '.pdf') {
      if (!String.fromCharCodes(input.readBytes(5).toUint8List())
          .startsWith('%PDF-')) {
        throw const FormatException('Invalid PDF file.');
      }
      return {'profile': 'PDF', 'count': 0};
    }
    final archive = ZipDecoder().decodeStream(input);
    if (extension == '.epub') {
      final document = EpubDocument.open(file);
      try {
        return {
          'profile': 'EPUB',
          'count': document.chapters.length,
          if (document.title.isNotEmpty) 'title': document.title,
        };
      } finally {
        document.close();
      }
    }
    final images = _comicEntries(archive);
    if (images.isEmpty) {
      throw const FormatException('This archive has no readable image pages.');
    }
    return {'profile': 'DIVINA', 'count': images.length};
  } finally {
    input.closeSync();
  }
}

List<ArchiveFile> _comicEntries(Archive archive) =>
    archive.files
        .where(
          (file) =>
              file.isFile &&
              !file.name
                  .split('/')
                  .any((part) => part.startsWith('.') || part == '__MACOSX') &&
              [
                '.jpg',
                '.jpeg',
                '.png',
                '.webp',
                '.gif',
                '.bmp',
              ].contains(p.extension(file.name).toLowerCase()),
        )
        .toList()
      ..sort((a, b) => _natural(a.name, b.name));

int _natural(String a, String b) {
  final chunks = RegExp(r'\d+|\D+');
  final aa = chunks
      .allMatches(a.toLowerCase())
      .map((m) => m.group(0)!)
      .toList();
  final bb = chunks
      .allMatches(b.toLowerCase())
      .map((m) => m.group(0)!)
      .toList();
  for (var i = 0; i < aa.length && i < bb.length; i++) {
    final x = int.tryParse(aa[i]), y = int.tryParse(bb[i]);
    final order = x != null && y != null
        ? x.compareTo(y)
        : aa[i].compareTo(bb[i]);
    if (order != 0) return order;
  }
  final length = aa.length.compareTo(bb.length);
  return length == 0 ? a.compareTo(b) : length;
}

/// ZIP indexing and inflate run off the UI isolate. Pages are read on demand,
/// never extracted to caller-provided filesystem paths.
class LocalComicPages implements RasterPages {
  LocalComicPages(this.file);
  final File file;
  final _cache = WeightedCache<int, Uint8List>(
    maxWeight: 32 * 1024 * 1024,
    maxEntries: 8,
    weight: (bytes) => bytes.length,
  );
  final _pending = <int, Future<Uint8List>>{};
  @override
  List<Json> get dimensions => const [];
  @override
  Future<Uint8List> page(int number, {bool refresh = false}) async {
    if (refresh) _cache.remove(number);
    final cached = _cache[number];
    if (cached != null) return cached;
    final pending = _pending[number];
    if (pending != null) return pending;
    final path = file.path;
    final task = Isolate.run(() => _readComicPage(path, number));
    _pending[number] = task;
    try {
      final bytes = await task;
      _cache.put(number, bytes);
      return bytes;
    } finally {
      _pending.remove(number);
    }
  }
}

Uint8List _readComicPage(String path, int number) {
  final input = InputFileStream(path);
  try {
    final entries = _comicEntries(ZipDecoder().decodeStream(input));
    if (number < 1 || number > entries.length) {
      throw RangeError.range(number, 1, entries.length);
    }
    final entry = entries[number - 1];
    if (entry.size > 64 * 1024 * 1024) {
      throw const FormatException('Comic page exceeds 64 MiB.');
    }
    return Uint8List.fromList(entry.content);
  } finally {
    input.closeSync();
  }
}
