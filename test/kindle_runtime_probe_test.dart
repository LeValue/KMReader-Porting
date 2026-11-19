import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/conversion.dart';
import 'package:kmreader/core/kindle/positions.dart';
import 'package:kmreader/core/kindle/repository.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Opt-in personal runner check. Only the fixed metrics below may be uploaded.
void main() {
  final path = Platform.environment['KMREADER_KINDLE_PRIVATE_SESSION'];
  final installed =
      Platform.environment['KMREADER_KINDLE_PROBE_INSTALLED'] == 'true';
  test(
    installed
        ? 'personal Kindle runtime diagnoses the installed reader’s cached position'
        : 'personal Kindle runtime reads covers and completes the actual pinned download queue',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'kmreader-kindle-readonly-',
      );
      final store = LocalStore(sqlite3.open('${root.path}/store.sqlite'));
      final transport = _ReadOnlyClient();
      KindleRepository? repo;
      final report = <String, dynamic>{
        'schema': 1,
        'amazon_annotation_writes': 0,
      };
      try {
        NativeKindlePreparation.executableOverride =
            Platform.environment['KMREADER_KINDLE_WORKER'];
        final payload = object(jsonDecode(await File(path!).readAsString()));
        final session = KindleSession(object(payload['session']));
        final fixtureOnly =
            Platform.environment['KMREADER_KINDLE_RUNTIME_FIXTURE'] == 'true';
        final generated = object(payload['probe_operation']);
        report['generated_fixture_only'] = fixtureOnly;
        final profile = ServerProfile(
          id: session.id,
          name: 'Read-only check',
          email: '',
          url: 'https://www.amazon.it',
          source: 'kindle',
          authentication: Authentication.apiKey,
        );
        repo = KindleRepository(
          profile: profile,
          store: store,
          directory: root,
          client: KindleClient(session: session, client: transport),
        );
        if (installed) {
          await _installedPosition(repo, report);
          if (Platform.environment['KMREADER_KINDLE_REQUIRE_OFFER'] == 'true' &&
              report['offer_after_conflict'] != true) {
            throw const KindleFailure('probe_conflict_without_offer');
          }
          report['passed'] = true;
          return;
        }
        final clock = Stopwatch()..start();
        await repo.library.refresh();
        report['catalog_ms'] = clock.elapsedMilliseconds;
        final candidates = repo.library.items
            .where(
              (item) =>
                  item['type'] == 'PDOC' &&
                  (!fixtureOnly ||
                      item['id'] == generated['catalog_id'] &&
                          item['title'] == generated['title']),
            )
            .take(5)
            .toList();
        if (candidates.isEmpty) {
          throw const KindleFailure('probe_fixture_missing');
        }
        var selected = candidates.first;
        var annotationsExpected = false;
        // Prefer a book with existing cloud annotations, so the live import
        // check cannot silently succeed by testing an unannotated document.
        for (final candidate in candidates) {
          try {
            final sidecar = await repo.library.client.sidecar(
              candidate,
              annotations: true,
            );
            if ((sidecar?['records'] as List? ?? [])
                .map(object)
                .any(
                  (r) => const {
                    'kindle.bookmark',
                    'kindle.highlight',
                    'kindle.note',
                  }.contains(r['type']),
                )) {
              selected = candidate;
              annotationsExpected = true;
              break;
            }
          } on KindleFailure {
            /* Availability is reported by the app check. */
          }
        }
        report['annotations_expected'] = annotationsExpected;
        final id = repo.library.idFor(selected);
        clock.reset();
        final cover = await repo.library.cover(id);
        report['cover_ms'] = clock.elapsedMilliseconds;
        report['cover_available_before_download'] =
            cover != null && await cover.exists();
        clock.reset();
        final book = await repo.book(id);
        await repo.download(book);
        report['download_and_prepare_ms'] = clock.elapsedMilliseconds;
        report['download_ready'] =
            store.download(profile.id, id)?['status'] == 'ready';
        report['pages_available'] = (await repo.book(id)).pages > 0;
        final requests = transport.requests;
        clock.reset();
        await repo.library.download(
          id,
          File('${root.path}/cached-copy.document'),
        );
        report['prepared_cache_ms'] = clock.elapsedMilliseconds;
        report['cached_copy_network_requests'] = transport.requests - requests;
        // Loading remote locators/annotations is read-only; never call save or
        // documentPosition from this probe.
        final prepared = await repo.book(id);
        await repo.externalDocumentPosition(prepared, repo.bookFile(prepared));
        report['annotation_count'] = repo.documentAnnotations(prepared).length;
        report['annotation_edition_matches'] =
            object(
              store.cached(profile.id, 'kindle:availability:$id'),
            )['edition_matches'] ==
            true;
        expect(report['download_ready'], true);
        // The generated EPUB deliberately has no cover resource.
        if (!fixtureOnly) {
          expect(report['cover_available_before_download'], true);
        }
        expect(report['pages_available'], true);
        expect(report['cached_copy_network_requests'], 0);
        if (annotationsExpected) {
          expect(report['annotation_count'] as int, greaterThan(0));
        }
        report['passed'] = true;
      } catch (error) {
        report['passed'] = false;
        report['error_code'] = error is KindleFailure
            ? error.code
            : 'runtime_check';
        fail(
          'Read-only Kindle runtime check failed; inspect sanitized metrics.',
        );
      } finally {
        repo?.dispose();
        transport.close();
        store.close();
        await root.delete(recursive: true);
        final output = Platform.environment['KMREADER_KINDLE_PROBE_REPORT'];
        if (output != null) {
          await File(output).writeAsString(jsonEncode(report));
        }
      }
    },
    skip: path == null || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

/// Read only the selected account and one already-prepared book from the
/// installed app. The repository writes its probe state to the temporary
/// database. Report fields below never include content, positions or IDs.
Future<void> _installedPosition(KindleRepository repo, Json report) async {
  report['installed_position'] = true;
  final home =
      Platform.environment['KMREADER_DATA_DIR'] ??
      p.join(Platform.environment['APPDATA']!, 'dev.levalue', 'KMReader');
  final dbPath = p.join(home, 'kmreader.sqlite');
  if (!File(dbPath).existsSync()) {
    throw const KindleFailure('probe_installed_database_missing');
  }
  final source = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  final id = repo.profile.id;
  dynamic cache(String key) {
    final rows = source.select(
      'SELECT value FROM cache WHERE server=? AND key=?',
      [id, key],
    );
    return rows.isEmpty ? null : jsonDecode(rows.single['value'] as String);
  }

  dynamic setting(String key) {
    final rows = source.select('SELECT value FROM settings WHERE key=?', [key]);
    return rows.isEmpty ? null : jsonDecode(rows.single['value'] as String);
  }

  late final Book book;
  late final File file;
  late final Json pending;
  try {
    if (source.select('SELECT 1 FROM servers WHERE id=?', [id]).isEmpty) {
      throw const KindleFailure('probe_installed_account_mismatch');
    }
    report['installed_account_matches'] = true;
    final outbox = object(cache('kindle:outbox'));
    final latest = source.select(
      "SELECT key FROM cache WHERE server=? AND key LIKE 'epub:%' "
      "ORDER BY updated DESC LIMIT 20",
      [id],
    );
    final bookId = [
      ...outbox.keys,
      for (final row in latest) (row['key'] as String).substring(5),
    ].where((key) => RegExp(r'^[a-f0-9]{64}$').hasMatch(key)).firstOrNull;
    if (bookId == null) {
      throw const KindleFailure('probe_installed_book_missing');
    }
    report['installed_sync_enabled'] = setting('kindleSync:$id') != false;
    report['installed_offline'] = setting('offline:$id') == true;
    report['installed_auto_resume'] = setting('kindleAutoResume:$id') == true;
    report['installed_native_epub'] =
        setting('epubRenderingEngine') == 'native';
    final saved = object(cache('epub:$bookId'));
    report['installed_has_cfi'] = text(saved['cfi']).isNotEmpty;
    pending = object(outbox[bookId]);
    report['installed_has_pending'] = pending.isNotEmpty;
    final pinned = File(
      p.join(home, id, 'books', repo.fileKey(bookId), 'source.document'),
    );
    final cached = text(object(cache('documentCache:$bookId'))['file']);
    file = pinned.existsSync()
        ? pinned
        : File(
            p.join(
              home,
              id,
              'documents',
              RegExp(r'^[a-f0-9]{64}-[0-9]+\.epub$').hasMatch(cached)
                  ? cached
                  : 'missing',
            ),
          );
    if (!file.existsSync()) {
      throw const KindleFailure('probe_installed_publication_missing');
    }
    final metadata = cache('book:$bookId');
    for (final key in [
      'kindle:catalog',
      'epub:$bookId',
      'kindle:sidecar:$bookId',
      'kindle:cloud-read:$bookId',
    ]) {
      final value = cache(key);
      if (value != null) repo.store.cache(id, key, value);
    }
    if (metadata != null) repo.store.cache(id, 'book:$bookId', metadata);
    final progress = source.select(
      'SELECT value FROM progress WHERE server=? AND book=?',
      [id, bookId],
    );
    if (progress.isNotEmpty) {
      repo.store.recordProgress(
        id,
        bookId,
        object(jsonDecode(progress.single['value'] as String)),
        pending: false,
      );
    }
    await repo.library.initialize();
    // Select the cached item without asking the remote catalog for other books.
    repo.library.item(bookId);
    book = await repo.book(bookId);
    report['installed_completed'] = book.completed;
  } finally {
    source.close();
  }

  final mapping = await KindlePositionMap.open(file.path);
  if (mapping == null || mapping.primary == null || mapping.entries.isEmpty) {
    throw const KindleFailure('probe_installed_map_missing');
  }
  final item = repo.library.item(book.id);
  final (edition, account) = await (
    repo.library.client.sidecar(item, guid: mapping.primary),
    repo.library.client.accountPositionSidecar(item),
  ).wait;
  final scopedMatch = edition != null && mapping.matches(edition);
  final accountMatch = account != null && mapping.matches(account);
  final remote = kindleLastRead(
    scopedMatch ? edition : null,
    account: accountMatch ? account : null,
  );
  report['edition_matches'] = scopedMatch;
  report['account_edition_matches'] = accountMatch;
  report['remote_location_available'] = remote != null;
  report['remote_location_mapped'] =
      remote != null && mapping.locator(integer(remote['position'])) != null;
  report['account_and_edition_differ'] =
      kindleLastRead(edition)?['position'] !=
      kindleLastRead(account)?['position'];
  report['remote_timestamp_available'] =
      kindleTimestamp(remote?['time']) != null;
  report['pending_differs_from_cloud'] =
      pending.isNotEmpty &&
      remote != null &&
      pending['position'] != remote['position'];

  final initial = await repo.externalDocumentPosition(book, file);
  report['offer_without_pending'] = initial != null;
  if (pending.isNotEmpty) {
    repo.store.cache(id, 'kindle:outbox', {
      book.id: {...pending, 'not_before': 0},
    });
    // The transport refuses any position write, even if the repository would
    // normally send it on finding no conflict. Only the scratch store changes.
    await repo.sync();
    report['pending_conflict_detected'] = repo.conflicts.containsKey(book.id);
    report['can_apply_after_conflict'] = repo.canApplyDocumentPosition(book);
    final offer = await repo.refreshDocumentPosition(book);
    report['offer_after_conflict'] = offer != null;
    if (offer != null &&
        Platform.environment['KMREADER_KINDLE_REQUIRE_OFFER'] == 'true') {
      final conflict = repo.readingConflicts[book.id];
      final accepted =
          conflict != null && repo.useKindlePosition(book.id, conflict);
      final selected = await repo.externalDocumentPosition(book, file);
      report['choice_reopens_at_verified_locator'] =
          accepted &&
          selected?['acceptedConflict'] == true &&
          selected?['position'] == offer['position'] &&
          selected?['offset'] == offer['offset'];
      if (report['choice_reopens_at_verified_locator'] != true) {
        throw const KindleFailure('probe_choice_not_restorable');
      }
    }
  }
}

class _ReadOnlyClient extends http.BaseClient {
  final delegate = http.Client();
  int requests = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method != 'GET' &&
        !(request.method == 'POST' &&
            request.url.host == 'api.amazon.it' &&
            request.url.path.startsWith('/auth/'))) {
      throw const KindleFailure('read_only_guard');
    }
    requests++;
    return delegate.send(request);
  }

  @override
  void close() => delegate.close();
}
