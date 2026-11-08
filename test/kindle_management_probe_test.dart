import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/management.dart';
import 'package:kmreader/core/kindle/repository.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// Destructive only for the exact generated EPUB identified by the local vault.
void main() {
  final path =
      Platform.environment['KMREADER_KINDLE_MANAGEMENT_PRIVATE_SESSION'];
  test(
    'personal management deletes only the previously generated test PDOC',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'kmreader-management-probe-',
      );
      final store = LocalStore(sqlite3.openInMemory());
      KindleRepository? repo;
      final report = <String, dynamic>{
        'schema': 1,
        'existing_documents_modified': 0,
        'annotation_writes': 0,
      };
      try {
        final file = File(path!);
        final payload = object(jsonDecode(await file.readAsString()));
        final fixture = object(payload['probe_operation']);
        final rawId = text(fixture['catalog_id']);
        if (rawId.isEmpty ||
            !text(fixture['title']).startsWith('KMReader test ')) {
          throw const KindleFailure('management_probe_fixture_missing');
        }
        final journal = object(payload['management_probe']);
        payload['management_probe'] = journal;
        Future<void> seal() async {
          await file.writeAsString(jsonEncode(payload));
          final result = await Process.run('python', [
            '-m',
            'tool.kindle_send_probe_bridge',
            'seal',
            file.path,
          ]);
          if (result.exitCode != 0) {
            throw const KindleFailure('management_probe_private_journal');
          }
        }

        final transport = _ManagementProbeClient(rawId, report);
        final session = KindleSession(object(payload['session']));
        final client = KindleClient(
          session: session,
          client: transport,
          saveSession: (value) async {
            payload['session'] = value.json;
            await file.writeAsString(jsonEncode(payload));
          },
        );
        final profile = ServerProfile(
          id: session.id,
          name: 'Management probe',
          url: 'https://www.amazon.it',
          email: '',
          source: 'kindle',
          authentication: Authentication.apiKey,
        );
        repo = KindleRepository(
          profile: profile,
          store: store,
          directory: root,
          client: client,
        );
        await repo.library.refresh(full: true);
        final matches = repo.library.items
            .where(
              (item) =>
                  item['id'] == rawId &&
                  item['type'] == 'PDOC' &&
                  item['title'] == fixture['title'],
            )
            .toList();
        final manager = KindleDocumentManager(repo);
        final saved = journal['operations'];
        if (saved is List) store.cache(profile.id, 'kindle:management', saved);
        transport.beforeDelete = () async {
          journal['state'] = 'submitted';
          journal['operations'] = manager.operations;
          final backups = <String, String>{};
          for (final op in manager.operations) {
            final backup = File(
              '${root.path}/${profile.id}/kindle-management/${op['backup']}',
            );
            if (await backup.exists()) {
              backups[text(op['backup'])] = await backup.readAsString();
            }
          }
          journal['backups'] = backups;
          await seal();
        };
        if (manager.operations.isNotEmpty) {
          final op = manager.operations.last;
          report['deletion_confirmed'] = await manager.verifyDeletion(
            text(op['operation']),
          );
        } else if (matches.length == 1) {
          journal['state'] = 'starting';
          await seal();
          try {
            await manager.delete(Book(repo.library.bookJson(matches.single)));
          } finally {
            journal['operations'] = manager.operations;
            journal['state'] = transport.deletions > 0
                ? 'submitted'
                : 'preflight_failed';
            await seal();
          }
          report['deletion_confirmed'] =
              manager.operations.last['state'] == 'done';
        } else {
          throw const KindleFailure('management_probe_fixture_not_unique');
        }
        journal['operations'] = manager.operations;
        await seal();
        report['delete_submissions'] = transport.deletions;
        report['operation_state'] = manager.operations.last['state'];
        report['passed'] = report['deletion_confirmed'] == true;
        if (report['passed'] != true) {
          fail('Deletion not yet confirmed; no automatic replay.');
        }
      } catch (error) {
        report['passed'] = false;
        if (error is KindleFailure) {
          report['error_code'] = error.code;
          report['http_status'] = error.status;
        } else {
          report['error_code'] = 'management_probe';
        }
        fail('Management check failed; inspect sanitized metrics.');
      } finally {
        await repo?.stopDownloadWork();
        repo?.dispose();
        store.close();
        await root.delete(recursive: true);
        final output =
            Platform.environment['KMREADER_KINDLE_MANAGEMENT_REPORT'];
        if (output != null) {
          await File(output).writeAsString(jsonEncode(report));
        }
      }
    },
    skip: path == null || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

class _ManagementProbeClient extends http.BaseClient {
  _ManagementProbeClient(this.id, this.report);
  final String id;
  final Json report;
  final delegate = http.Client();
  Future<void> Function()? beforeDelete;
  int deletions = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    final web = uri.host == 'www.amazon.it';
    final deletion =
        web &&
        uri.path == '/mn/dcw/myx/ajax-activity/ref=myx_ajax' &&
        request.method == 'POST';
    final read =
        request.method == 'GET' &&
        (web && uri.path == '/hz/mycd/myx' ||
            uri.host == 'todo-ta-g7g.amazon.com' &&
                uri.path == '/FionaTodoListProxy/syncMetaData' ||
            uri.host == 'cde-ta-g7g.amazon.com' &&
                uri.path == '/FionaCDEServiceEngine/sidecar' &&
                uri.queryParameters['key'] == id);
    final auth =
        request.method == 'POST' &&
        (web && uri.path == '/ap/exchangetoken/cookies' ||
            uri.host == 'api.amazon.it' && uri.path == '/auth/token');
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        !(read || auth || deletion)) {
      throw const KindleFailure('management_probe_guard');
    }
    if (deletion) {
      if (++deletions > 1 || request is! http.Request) {
        throw const KindleFailure('management_probe_delete_limit');
      }
      final data = object(jsonDecode(request.bodyFields['data'] ?? '{}'));
      final details = object(
        object(object(data['param'])['DeleteContent'])['asinDetails'],
      );
      if (details.length != 1 ||
          details.keys.single != id ||
          object(details[id])['category'] != 'KindlePDoc') {
        throw const KindleFailure('management_probe_document_guard');
      }
      await beforeDelete!();
      report['delete_submissions'] = deletions;
    }
    final response = await delegate.send(request);
    final steps = report['steps'] ??= <Json>[];
    (steps as List).add({
      'step': deletion ? 'delete' : uri.path,
      'http_status': response.statusCode,
    });
    if (!web || uri.path != '/hz/mycd/myx') return response;
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 60),
    )) {
      if (bytes.length + chunk.length > 4 * 1024 * 1024) {
        throw const KindleFailure('response_size');
      }
      bytes.addAll(chunk);
    }
    final page = html.parse(utf8.decode(bytes));
    report['public_scripts'] = page
        .querySelectorAll('script[src]')
        .map((e) => Uri.tryParse(e.attributes['src'] ?? ''))
        .whereType<Uri>()
        .where(
          (u) =>
              u.scheme == 'https' &&
              u.host == 'm.media-amazon.com' &&
              u.path.startsWith('/images/I/') &&
              u.query.isEmpty &&
              u.userInfo.isEmpty,
        )
        .map((u) => u.toString())
        .take(20)
        .toList();
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() => delegate.close();
}
