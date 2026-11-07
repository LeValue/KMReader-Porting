import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/conversion.dart';
import 'package:kmreader/core/kindle/repository.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// Opt-in personal runner check. Only the fixed metrics below may be uploaded.
void main() {
  final path = Platform.environment['KMREADER_KINDLE_PRIVATE_SESSION'];
  test(
    'personal Kindle runtime reads covers and completes the actual pinned download queue',
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
        final session = KindleSession(
          object(
            object(jsonDecode(await File(path!).readAsString()))['session'],
          ),
        );
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
        final clock = Stopwatch()..start();
        await repo.library.refresh();
        report['catalog_ms'] = clock.elapsedMilliseconds;
        final candidates = repo.library.items
            .where((item) => item['type'] == 'PDOC')
            .take(5)
            .toList();
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
        expect(report['cover_available_before_download'], true);
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
