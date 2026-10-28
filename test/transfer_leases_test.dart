import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('independent database connections cannot download the same book until lease expiry', () {
    final dir = Directory.systemTemp.createTempSync('transfer-leases-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final first = LocalStore(sqlite3.open('${dir.path}/db.sqlite')),
        second = LocalStore(sqlite3.open('${dir.path}/db.sqlite'));
    addTearDown(first.close);
    addTearDown(second.close);
    expect(
      first.claimTransfer('a', 'one', 'foreground', now: 1000, lifetime: 100),
      true,
    );
    expect(second.claimTransfer('a', 'one', 'background', now: 1050), false);
    expect(second.claimTransfer('a', 'two', 'background', now: 1050), true);
    first.releaseTransfer('a', 'one', 'wrong-owner');
    expect(second.claimTransfer('a', 'one', 'background', now: 1060), false);
    expect(second.claimTransfer('a', 'one', 'background', now: 1101), true);
    first.releaseTransfer('a', 'one', 'foreground');
    expect(first.claimTransfer('a', 'one', 'foreground', now: 1102), false);
  });
  test('late worker writes cannot recreate an account removed by another connection', () {
    final dir = Directory.systemTemp.createTempSync('transfer-removal-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final main = LocalStore(sqlite3.open('${dir.path}/db.sqlite')),
        worker = LocalStore(sqlite3.open('${dir.path}/db.sqlite'));
    addTearDown(main.close);
    addTearDown(worker.close);
    const profile = ServerProfile(
      id: 'account',
      name: 'Server',
      url: 'https://example.invalid',
      email: '',
      authentication: Authentication.apiKey,
    );
    main.saveServer(profile);
    main.removeServer(profile.id);
    final book = Book({'id': 'one', 'name': 'Book'});
    worker.saveDownload(profile.id, book, 'ready');
    worker.cacheBooks(profile.id, [CatalogItem('books', book.json)]);
    worker.recordProgress(profile.id, book.id, {'page': 2});
    expect(worker.claimTransfer(profile.id, book.id, 'worker'), false);
    expect(main.downloads(profile.id), isEmpty);
    expect(main.cachedBooks(profile.id), isEmpty);
    expect(main.offlineCatalog.count(profile.id, 'books'), 0);
    expect(main.pendingCount(profile.id), 0);
    main.saveServer(profile);
    worker.saveDownload(profile.id, book, 'queued');
    expect(main.downloads(profile.id), hasLength(1));
  });
}
