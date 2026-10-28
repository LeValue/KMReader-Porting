import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'models.dart';
import 'offline_catalog.dart';

class LocalStore {
  LocalStore(this.db) {
    db.execute('PRAGMA foreign_keys=ON');
    db.execute('PRAGMA busy_timeout=5000');
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
    offlineCatalog = OfflineCatalog(db);
    if (setting<bool>('offlineIndexMigrated') != true) {
      db.execute('BEGIN IMMEDIATE');
      try {
        for (final row in db.select(
          "SELECT server,key,value FROM cache WHERE key LIKE 'book:%' OR key LIKE 'detail:%'",
        )) {
          final key = row['key'] as String;
          final kind = key.startsWith('book:') ? 'books' : key.split(':')[1];
          if (!['books', 'series', 'collections', 'readlists'].contains(kind)) {
            continue;
          }
          final value = object(jsonDecode(row['value'] as String));
          if (text(value['id']).isNotEmpty) {
            offlineCatalog.put(
              row['server'] as String,
              CatalogItem(kind, value),
            );
          }
        }
        setSetting('offlineIndexMigrated', true);
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
    db.execute(
      'CREATE TABLE IF NOT EXISTS removed_accounts(server TEXT PRIMARY KEY)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS transfer_leases(server TEXT NOT NULL,book TEXT NOT NULL,owner TEXT NOT NULL,expires INTEGER NOT NULL,PRIMARY KEY(server,book))',
    );
    for (final table in [
      'cache',
      'progress',
      'downloads',
      'catalog_records',
      'transfer_leases',
    ]) {
      db.execute(
        'CREATE TRIGGER IF NOT EXISTS ${table}_removed_account BEFORE INSERT ON $table WHEN EXISTS(SELECT 1 FROM removed_accounts WHERE server=new.server) BEGIN SELECT RAISE(IGNORE); END',
      );
    }
    db.execute(
      'CREATE TABLE IF NOT EXISTS image_versions(server TEXT NOT NULL,path TEXT NOT NULL,generation INTEGER NOT NULL DEFAULT 0,stored_generation INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(server,path))',
    );
    if (!db
        .select('PRAGMA table_info(image_versions)')
        .any((row) => row['name'] == 'stored_generation')) {
      db.execute(
        'ALTER TABLE image_versions ADD COLUMN stored_generation INTEGER NOT NULL DEFAULT 0',
      );
    }
    for (final (name, definition) in [
      ('etag', 'TEXT'),
      ('modified', 'TEXT'),
      ('validated', 'INTEGER NOT NULL DEFAULT 0'),
    ]) {
      if (!db
          .select('PRAGMA table_info(image_versions)')
          .any((row) => row['name'] == name)) {
        db.execute('ALTER TABLE image_versions ADD COLUMN $name $definition');
      }
    }
    db.execute(
      "CREATE TRIGGER IF NOT EXISTS image_versions_removed_account BEFORE INSERT ON image_versions WHEN EXISTS(SELECT 1 FROM removed_accounts WHERE server=new.server) BEGIN SELECT RAISE(IGNORE); END",
    );
    db.execute('PRAGMA user_version=5');
  }
  final Database db;
  late final OfflineCatalog offlineCatalog;
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
  void saveServer(ServerProfile s) {
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute('DELETE FROM removed_accounts WHERE server=?', [s.id]);
      db.execute('INSERT OR REPLACE INTO servers(id,value) VALUES(?,?)', [
        s.id,
        jsonEncode(s.toJson()),
      ]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void removeServer(String id) {
    _progress.removeWhere((key, _) => key.startsWith('$id:'));
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute('INSERT OR IGNORE INTO removed_accounts(server) VALUES(?)', [
        id,
      ]);
      db.execute('DELETE FROM servers WHERE id=?', [id]);
      for (final table in [
        'cache',
        'progress',
        'downloads',
        'catalog_records',
        'image_versions',
      ]) {
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

  void cache(String server, String key, dynamic value) {
    db.execute(
      'INSERT OR REPLACE INTO cache(server,key,value,updated) VALUES(?,?,?,?)',
      [server, key, jsonEncode(value), DateTime.now().millisecondsSinceEpoch],
    );
    final kind = key.startsWith('book:')
        ? 'books'
        : key.startsWith('detail:')
        ? key.split(':')[1]
        : null;
    if (kind != null &&
        value is Map &&
        text(value['id']).isNotEmpty &&
        ['books', 'series', 'collections', 'readlists'].contains(kind)) {
      offlineCatalog.put(server, CatalogItem(kind, object(value)));
    }
  }

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

  bool accountRemoved(String server) => db.select(
    'SELECT 1 FROM removed_accounts WHERE server=?',
    [server],
  ).isNotEmpty;
  bool claimTransfer(
    String server,
    String book,
    String owner, {
    int? now,
    int lifetime = 30000,
  }) {
    final stamp = now ?? DateTime.now().millisecondsSinceEpoch;
    db.execute(
      'INSERT INTO transfer_leases(server,book,owner,expires) VALUES(?,?,?,?) ON CONFLICT(server,book) DO UPDATE SET owner=excluded.owner,expires=excluded.expires WHERE transfer_leases.expires<=? OR transfer_leases.owner=excluded.owner',
      [server, book, owner, stamp + lifetime, stamp],
    );
    return db.updatedRows == 1;
  }

  void refreshTransfer(String server, String book, String owner) => db.execute(
    'UPDATE transfer_leases SET expires=? WHERE server=? AND book=? AND owner=?',
    [DateTime.now().millisecondsSinceEpoch + 30000, server, book, owner],
  );
  bool transferring(String server, String book) => db.select(
    'SELECT 1 FROM transfer_leases WHERE server=? AND book=? AND expires>?',
    [server, book, DateTime.now().millisecondsSinceEpoch],
  ).isNotEmpty;
  bool accountTransferring(String server) => db.select(
    'SELECT 1 FROM transfer_leases WHERE server=? AND expires>? LIMIT 1',
    [server, DateTime.now().millisecondsSinceEpoch],
  ).isNotEmpty;
  void releaseTransfer(String server, String book, String owner) => db.execute(
    'DELETE FROM transfer_leases WHERE server=? AND book=? AND owner=?',
    [server, book, owner],
  );
  void downloadFraction(String server, String book, double fraction) =>
      db.execute(
        "UPDATE downloads SET value=json_set(value,'\$.fraction',?,'\$.status','downloading') WHERE server=? AND book=? AND json_extract(value,'\$.status') NOT IN ('cancelled','ready')",
        [fraction, server, book],
      );

  void deleteDownload(String server, String book) => db.execute(
    'DELETE FROM downloads WHERE server=? AND book=?',
    [server, book],
  );
  Json imageState(String server, String path) {
    final rows = db.select(
      'SELECT * FROM image_versions WHERE server=? AND path=?',
      [server, path],
    );
    return rows.isEmpty ? {} : Map<String, dynamic>.from(rows.first);
  }

  void imageValidated(
    String server,
    String path,
    int version, {
    String? etag,
    String? modified,
  }) => db.execute(
    'INSERT INTO image_versions(server,path,generation,etag,modified,validated) VALUES(?,?,?,?,?,?) ON CONFLICT(server,path) DO UPDATE SET etag=excluded.etag,modified=excluded.modified,validated=excluded.validated WHERE image_versions.generation=excluded.generation',
    [
      server,
      path,
      version,
      etag,
      modified,
      DateTime.now().millisecondsSinceEpoch,
    ],
  );

  int imageVersion(String server, String path) {
    final rows = db.select(
      'SELECT generation FROM image_versions WHERE server=? AND path=?',
      [server, path],
    );
    return rows.isEmpty ? 0 : rows.first['generation'] as int;
  }

  int storedImageVersion(String server, String path) {
    final rows = db.select(
      'SELECT stored_generation FROM image_versions WHERE server=? AND path=?',
      [server, path],
    );
    return rows.isEmpty ? 0 : rows.first['stored_generation'] as int;
  }

  void markImageStored(String server, String path, int version) => db.execute(
    'INSERT INTO image_versions(server,path,generation,stored_generation) VALUES(?,?,?,?) ON CONFLICT(server,path) DO UPDATE SET stored_generation=excluded.stored_generation WHERE image_versions.generation=excluded.generation',
    [server, path, version, version],
  );

  void advanceImageVersion(String server, String path) => db.execute(
    'INSERT INTO image_versions(server,path,generation) VALUES(?,?,1) ON CONFLICT(server,path) DO UPDATE SET generation=generation+1',
    [server, path],
  );

  int? _externalCacheVersion;
  int get externalRevision {
    final version = db.select('PRAGMA data_version').first.values.first as int;
    if (_externalCacheVersion != null && _externalCacheVersion != version) {
      _progress.clear();
    }
    _externalCacheVersion = version;
    return version;
  }

  void close() => db.close();
}
