import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'models.dart';

class LocalStore {
  LocalStore(this.db) {
    db.execute('PRAGMA foreign_keys=ON');
    db.execute('PRAGMA journal_mode=WAL');
    db.execute(
      '''CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)''',
    );
    db.execute(
      '''CREATE TABLE IF NOT EXISTS servers(id TEXT PRIMARY KEY, value TEXT NOT NULL)''',
    );
    db.execute('''CREATE TABLE IF NOT EXISTS cache(server TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
      PRIMARY KEY(server,key))''');
    if (!db
        .select('PRAGMA table_info(cache)')
        .any((r) => r['name'] == 'updated')) {
      db.execute(
        'ALTER TABLE cache ADD COLUMN updated INTEGER NOT NULL DEFAULT 0',
      );
    }
    db.execute('''CREATE TABLE IF NOT EXISTS progress(server TEXT NOT NULL, book TEXT NOT NULL,
      value TEXT NOT NULL, revision INTEGER NOT NULL, pending INTEGER NOT NULL,
      PRIMARY KEY(server,book))''');
    db.execute('''CREATE TABLE IF NOT EXISTS downloads(server TEXT NOT NULL, book TEXT NOT NULL,
      value TEXT NOT NULL, PRIMARY KEY(server,book))''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS progress_pending ON progress(server,pending)',
    );
    db.execute('PRAGMA user_version=2');
  }
  final Database db;
  final _progress = <String, Json?>{};
  T? setting<T>(String key) {
    final rows = db.select('SELECT value FROM settings WHERE key=?', [key]);
    return rows.isEmpty
        ? null
        : jsonDecode(rows.first['value'] as String) as T?;
  }

  void setSetting(String key, dynamic value) => db.execute(
    'INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)',
    [key, jsonEncode(value)],
  );
  List<ServerProfile> get servers => db
      .select('SELECT value FROM servers ORDER BY rowid')
      .map(
        (r) => ServerProfile.fromJson(object(jsonDecode(r['value'] as String))),
      )
      .toList();
  void saveServer(ServerProfile s) => db.execute(
    'INSERT OR REPLACE INTO servers(id,value) VALUES(?,?)',
    [s.id, jsonEncode(s.toJson())],
  );
  void removeServer(String id) {
    _progress.removeWhere((key, _) => key.startsWith('$id:'));
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute('DELETE FROM servers WHERE id=?', [id]);
      for (final table in ['cache', 'progress', 'downloads']) {
        db.execute('DELETE FROM $table WHERE server=?', [id]);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  dynamic cached(String server, String key) {
    final rows = db.select('SELECT value FROM cache WHERE server=? AND key=?', [
      server,
      key,
    ]);
    return rows.isEmpty ? null : jsonDecode(rows.first['value'] as String);
  }

  void cache(String server, String key, dynamic value) => db.execute(
    'INSERT OR REPLACE INTO cache(server,key,value,updated) VALUES(?,?,?,?)',
    [server, key, jsonEncode(value), DateTime.now().millisecondsSinceEpoch],
  );
  void deleteCache(String server, String key) =>
      db.execute('DELETE FROM cache WHERE server=? AND key=?', [server, key]);
  DateTime? cachedAt(String server, String key) {
    final rows = db.select(
      'SELECT updated FROM cache WHERE server=? AND key=?',
      [server, key],
    );
    return rows.isEmpty
        ? null
        : DateTime.fromMillisecondsSinceEpoch(integer(rows.first['updated']));
  }

  void cacheBooks(String server, Iterable<CatalogItem> books) {
    cacheItems(server, books);
  }

  void cacheItems(String server, Iterable<CatalogItem> books) {
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final book in books) {
        cache(
          server,
          book.kind == 'books'
              ? 'book:${book.id}'
              : 'detail:${book.kind}:${book.id}',
          book.json,
        );
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<Book> cachedBooks(String server) => db
      .select("SELECT value FROM cache WHERE server=? AND key LIKE 'book:%'", [
        server,
      ])
      .map((row) => Book(object(jsonDecode(row['value'] as String))))
      .toList();

  int pendingCount(String server) => integer(
    db.select(
      'SELECT COUNT(*) AS count FROM progress WHERE server=? AND pending=1',
      [server],
    ).first['count'],
  );
  bool isPending(String server, String book) => db.select(
    'SELECT 1 FROM progress WHERE server=? AND book=? AND pending=1',
    [server, book],
  ).isNotEmpty;
  void recordProgress(String server, String book, Json value) {
    _progress['$server:$book'] = value;
    final previous = db.select(
      'SELECT revision FROM progress WHERE server=? AND book=?',
      [server, book],
    );
    final revision = previous.isEmpty
        ? 1
        : integer(previous.first['revision']) + 1;
    db.execute(
      'INSERT OR REPLACE INTO progress(server,book,value,revision,pending) VALUES(?,?,?,?,1)',
      [server, book, jsonEncode(value), revision],
    );
  }

  Json? progress(String server, String book) {
    final key = '$server:$book';
    if (_progress.containsKey(key)) return _progress[key];
    final rows = db.select(
      'SELECT value FROM progress WHERE server=? AND book=?',
      [server, book],
    );
    return _progress[key] = rows.isEmpty
        ? null
        : object(jsonDecode(rows.first['value'] as String));
  }

  void recordProgressBatch(String server, Map<String, Json> values) {
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final entry in values.entries) {
        recordProgress(server, entry.key, entry.value);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      for (final id in values.keys) {
        _progress.remove('$server:$id');
      }
      rethrow;
    }
  }

  List<Json> pending(String server) => db
      .select(
        'SELECT book,value,revision FROM progress WHERE server=? AND pending=1',
        [server],
      )
      .map(
        (r) => {
          'book': r['book'],
          'value': jsonDecode(r['value'] as String),
          'revision': r['revision'],
        },
      )
      .toList();
  void acknowledge(String server, String book, int revision) => db.execute(
    'UPDATE progress SET pending=0 WHERE server=? AND book=? AND revision=?',
    [server, book, revision],
  );
  void saveDownload(
    String server,
    Book book,
    String status, {
    String? error,
    int size = 0,
  }) => db.execute(
    'INSERT OR REPLACE INTO downloads(server,book,value) VALUES(?,?,?)',
    [
      server,
      book.id,
      jsonEncode({
        'book': book.json,
        'status': status,
        'error': error,
        'size': size,
        'time': DateTime.now().toIso8601String(),
      }),
    ],
  );
  List<Json> downloads(String server) => db
      .select('SELECT value FROM downloads WHERE server=?', [server])
      .map((r) => object(jsonDecode(r['value'] as String)))
      .toList();
  Json? download(String server, String book) {
    final rows = db.select(
      'SELECT value FROM downloads WHERE server=? AND book=?',
      [server, book],
    );
    return rows.isEmpty
        ? null
        : object(jsonDecode(rows.first['value'] as String));
  }

  void deleteDownload(String server, String book) => db.execute(
    'DELETE FROM downloads WHERE server=? AND book=?',
    [server, book],
  );
  void close() => db.close();
}
