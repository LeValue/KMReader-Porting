import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as image;
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/conversion.dart';
import 'package:kmreader/core/kindle/document_edit.dart';
import 'package:kmreader/core/kindle/import.dart';
import 'package:kmreader/core/kindle/management.dart';
import 'package:kmreader/core/kindle/positions.dart';
import 'package:kmreader/core/kindle/repository.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:xml/xml.dart';
import 'package:file_selector/file_selector.dart';

/// Real overwrite lifecycle, exclusively for our generated cloud-only fixture.
/// The private DPAPI journal makes reruns verification-only after submission.
void main() {
  final path =
      Platform.environment['KMREADER_KINDLE_MANAGEMENT_PRIVATE_SESSION'];
  test(
    'generated document update restores cloud progress before retiring its previous version',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'kindle-replacement-probe-',
      );
      final store = LocalStore(sqlite3.openInMemory());
      KindleRepository? repo;
      final report = <String, dynamic>{
        'schema': 1,
        'existing_documents_modified': 0,
        'document_uploads': 0,
        'document_deletions': 0,
        'annotation_writes': 0,
      };
      Future<void> Function()? persist;
      Future<void> Function()? diagnose;
      try {
        final file = File(path!);
        final payload = object(jsonDecode(await file.readAsString()));
        final fixture = object(object(payload['delivery_probes'])['library']);
        final rawId = text(fixture['catalog_id']);
        if (rawId.isEmpty ||
            !text(fixture['title']).startsWith('KMReader test ')) {
          throw const KindleFailure('replacement_probe_fixture_missing');
        }
        final journals = object(payload['management_probe']);
        payload['management_probe'] = journals;
        final journal = object(journals['replacement_library']);
        journals['replacement_library'] = journal;
        const verifiedFields = [
          'completion_preserved',
          'read_date_preserved',
          'updated_cover_available',
          'updated_title_visible',
        ];
        for (final key in verifiedFields) {
          if (object(journal['verification'])[key] is bool) {
            report[key] = object(journal['verification'])[key];
          }
        }
        final session = KindleSession(object(payload['session']));
        final profile = ServerProfile(
          id: session.id,
          name: 'Generated replacement check',
          url: 'https://www.amazon.it',
          email: '',
          source: 'kindle',
          authentication: Authentication.apiKey,
        );
        final transport = _ReplacementTransport(rawId, journal, report);
        NativeKindlePreparation.executableOverride =
            Platform.environment['KMREADER_KINDLE_WORKER'];
        repo = KindleRepository(
          profile: profile,
          store: store,
          directory: root,
          client: KindleClient(session: session, client: transport),
        );
        final repository = repo;
        final manager = KindleDocumentManager(repository);
        final cloud = await manager.cloudDocuments();
        final cloudItems = (cloud['items'] as List).map(object).toList();
        String canonical(String value) =>
            RegExp(r'^[A-Fa-f0-9]{32}$').hasMatch(value)
            ? value.toUpperCase()
            : value;
        final pending = (journal['operations'] as List? ?? [])
            .map(object)
            .firstOrNull;
        report['cloud_inventory'] = {
          'complete': cloud['complete'] == true,
          'count': cloudItems.length,
          'source_id_present': cloudItems.any(
            (item) => canonical(text(item['asin'])) == canonical(rawId),
          ),
          'source_title_present': cloudItems.any(
            (item) => item['title'] == fixture['title'],
          ),
          'target_id_present': cloudItems.any(
            (item) =>
                canonical(text(item['asin'])) ==
                canonical(text(pending?['new_id'])),
          ),
          'target_title_present': cloudItems.any(
            (item) => item['title'] == journal['title'],
          ),
          'uuid_ids': cloudItems
              .where(
                (item) =>
                    RegExp(r'^[A-Fa-f0-9]{32}$').hasMatch(text(item['asin'])),
              )
              .length,
        };
        final folder = Directory(
          p.join(root.path, profile.id, 'kindle-management'),
        );
        await folder.create(recursive: true);
        for (final entry in object(journal['files']).entries) {
          if (p.basename(entry.key) != entry.key) {
            throw const KindleFailure('replacement_probe_journal');
          }
          await File(p.join(folder.path, entry.key))
              .writeAsBytes(base64Decode(text(entry.value)));
        }
        if (journal['operations'] is List) {
          store.cache(profile.id, 'kindle:management', journal['operations']);
        }
        for (final entry in object(journal['progress']).entries) {
          store.recordProgress(profile.id, entry.key, object(entry.value));
        }
        for (final entry in object(journal['cache']).entries) {
          store.cache(profile.id, entry.key, entry.value);
        }
        persist = () async {
          journal['operations'] = manager.operations;
          final books = <String>{
            for (final op in manager.operations) text(op['book']),
            for (final op in manager.operations)
              if (object(op['migration_plan'])['target'] is String)
                text(object(op['migration_plan'])['target']),
          };
          journal['progress'] = {
            for (final book in books)
              if (store.progress(profile.id, book) != null)
                book: store.progress(profile.id, book),
          };
          journal['cache'] = {
            for (final book in books)
              for (final key in ['epub:$book', 'epubBookmarks:$book'])
                if (store.cached(profile.id, key) != null)
                  key: store.cached(profile.id, key),
          };
          journal['files'] = {
            for (final file in folder.listSync().whereType<File>())
              p.basename(file.path): base64Encode(await file.readAsBytes()),
          };
          await file.writeAsString(jsonEncode(payload));
          final process = await Process.run('python', [
            '-m',
            'tool.kindle_send_probe_bridge',
            'seal',
            file.path,
          ]);
          if (process.exitCode != 0) {
            throw const KindleFailure('replacement_probe_journal');
          }
        };
        transport.beforeMutation = persist;
        diagnose = () async {
          if (manager.operations.length != 1) return;
          final operation = manager.operations.single;
          final backup = object(
            jsonDecode(
              await File(p.join(folder.path, text(operation['backup'])))
                  .readAsString(),
            ),
          );
          final mapping = await KindlePositionMap.open(
            p.join(folder.path, text(backup['source'])),
          );
          if (mapping == null) return;
          final current = await repository.library.client.sidecar(
            repository.library.item(text(operation['book'])),
            guid: mapping.primary,
            annotations: true,
          );
          final previous = object(backup['sidecar']);
          final oldRecords = (previous['records'] as List? ?? [])
              .map(object)
              .toList();
          final newRecords = (current?['records'] as List? ?? [])
              .map(object)
              .toList();
          final oldMarks = oldRecords
              .where((r) => r['type'] == 'kindle.bookmark')
              .toList();
          final newMarks = newRecords
              .where((r) => r['type'] == 'kindle.bookmark')
              .toList();
          final oldRead = kindleLastRead(previous),
              newRead = current == null ? null : kindleLastRead(current);
          final oldTime = DateTime.tryParse(text(oldRead?['time']));
          final newTime = DateTime.tryParse(text(newRead?['time']));
          report['migration_diagnostic'] = {
            'edition_snapshot_created': text(backup['source_guid']).isNotEmpty,
            'backup_edition_matches': mapping.matches(previous),
            'current_edition_matches':
                current != null && mapping.matches(current),
            'backup_complete': previous['annotations_complete'] == true,
            'current_complete': current?['annotations_complete'] == true,
            'backup_bookmark_count': oldMarks.length,
            'current_bookmark_count': newMarks.length,
            'annotation_ids_preserved': oldMarks.every(
              (a) =>
                  newMarks.any((b) => b['annotationId'] == a['annotationId']),
            ),
            'bookmark_positions_preserved': oldMarks.every(
              (a) => newMarks.any(
                (b) =>
                    num.tryParse('${a['startPosition']}') ==
                    num.tryParse('${b['startPosition']}'),
              ),
            ),
            'bookmark_raw_positions_equal': oldMarks.every(
              (a) =>
                  newMarks.any((b) => a['startPosition'] == b['startPosition']),
            ),
            'backup_position_present': oldRead != null,
            'current_position_present': newRead != null,
            'positions_equal': oldRead?['position'] == newRead?['position'],
            'backup_position_matches_seed':
                oldRead?['position'] == journal['seed_position'],
            'current_position_matches_seed':
                newRead?['position'] == journal['seed_position'],
            'backup_time_present': oldTime != null,
            'current_time_present': newTime != null,
            'backup_time_after_current':
                oldTime != null && newTime != null && oldTime.isAfter(newTime),
          };
        };
        await repository.library.refresh(full: true);
        final originalItem = repository.library.items
            .where(
              (item) =>
                  item['id'] == rawId &&
                  item['title'] == fixture['title'] &&
                  item['type'] == 'PDOC',
            )
            .firstOrNull;
        if (manager.operations.isEmpty) {
          if (originalItem == null) {
            throw const KindleFailure('replacement_probe_original_missing');
          }
          final original = await repository.book(
            repository.library.idFor(originalItem),
          );
          final source = await manager.sourceForEdit(original);
          final mapping = await KindlePositionMap.open(source.path);
          if (mapping?.primary == null || mapping!.entries.isEmpty) {
            throw const KindleFailure('replacement_probe_mapping');
          }
          final anchor = mapping.entries.first;
          final position =
              integer(anchor['position']) +
              min<int>(2, integer(anchor['length']) - 1);
          final bookmark = integer(anchor['position']);
          journal['seed_guid'] = mapping.primary;
          journal['seed_position'] = position;
          journal['seed_bookmark'] = bookmark;
          if (journal['seed_state'] == null) {
            journal['seed_state'] = 'submitting';
            await persist();
            await repository.library.client.pushReadingState(
              originalItem,
              mapping.primary!,
              position: position,
              bookmarks: [bookmark],
            );
            journal['seed_state'] = 'confirmed';
            await persist();
          } else if (!await repository.library.client.readingStateConfirmed(
            originalItem,
            mapping.primary!,
            position: position,
            bookmarks: [bookmark],
          )) {
            throw const KindleFailure('replacement_probe_seed_uncertain');
          }
          report['source_reading_state_confirmed'] = true;
          store.recordProgress(profile.id, original.id, {
            'page': 17,
            'completed': true,
            'readDate': '2020-01-01T00:00:00Z',
          });
          store.cache(profile.id, 'epub:${original.id}', {'fontSize': 130});
          final title = text(journal['title']).isEmpty
              ? 'KMReader test updated ${DateTime.now().toUtc().millisecondsSinceEpoch}'
              : text(journal['title']);
          journal['title'] = title;
          final cover = File(p.join(root.path, 'cover.png'));
          await cover.writeAsBytes(
            image.encodePng(
              image.Image(width: 48, height: 64)
                ..clear(image.ColorRgb8(192, 30, 45)),
            ),
          );
          final prepared = File(p.join(root.path, 'updated.epub'));
          await editKindleEpub(
            source: source.path,
            target: prepared.path,
            title: title,
            author: 'KMReader test',
            cover: cover.path,
            summary: 'Generated metadata verification',
            language: 'it',
          );
          journal['size'] = await prepared.length();
          await persist();
          await manager.sendUpdatedVersion(
            original,
            XFile(prepared.path),
            title: title,
            author: 'KMReader test',
            cancel: KindleImportCancellation(),
          );
          await persist();
        }
        var operation = manager.operations.single;
        if (const {
          'replacement_submitting',
          'replacement_uncertain',
        }.contains(operation['state'])) {
          throw const KindleFailure('replacement_probe_delivery_uncertain');
        }
        if (const {
          'replacement_migration_required',
          'migration_submitting',
          'migration_uncertain',
        }.contains(operation['state'])) {
          // Catalog/conversion may lag acceptance; retries never repeat an upload
          // or a state mutation whose response was interrupted.
          for (var attempt = 0; attempt < 12; attempt++) {
            try {
              await manager.restoreReplacement(text(operation['operation']));
              break;
            } on KindleFailure catch (error) {
              await persist();
              if (attempt == 11 ||
                  !const {
                    'management_conversion_pending',
                    'amazon_request',
                    'management_migration_not_confirmed',
                  }.contains(error.code)) {
                rethrow;
              }
              await Future<void>.delayed(const Duration(seconds: 5));
            }
          }
          await persist();
          operation = manager.operations.single;
        }
        final plan = object(operation['migration_plan']);
        report['reading_state_restored'] =
            operation['state'] == 'progress_restored' ||
            text(operation['state']).startsWith('replacement_retir') ||
            operation['state'] == 'done';
        if (operation['state'] == 'progress_restored') {
          final updated = await repository.book(text(plan['target']));
          final state = store.progress(profile.id, updated.id);
          report['completion_preserved'] = state?['completed'] == true;
          report['read_date_preserved'] =
              state?['readDate'] == '2020-01-01T00:00:00Z';
          final cover = await repository.library.cover(updated.id);
          report['updated_cover_available'] =
              cover != null && await cover.exists();
          report['updated_title_visible'] =
              repository.library.item(updated.id)['title'] == journal['title'];
          journal['verification'] = {
            for (final key in verifiedFields) key: report[key],
          };
          await persist();
          if (verifiedFields.any((key) => report[key] != true)) {
            throw const KindleFailure('replacement_probe_metadata');
          }
          await manager.retireReplacement(text(operation['operation']));
          await persist();
        }
        operation = manager.operations.single;
        if (operation['state'] != 'done' &&
            text(operation['state']).startsWith('replacement_retir')) {
          for (var i = 0; i < 10; i++) {
            if (await manager.verifyDeletion(text(operation['operation']))) {
              break;
            }
            await Future<void>.delayed(const Duration(seconds: 3));
          }
          await persist();
        }
        report['operation_state'] = manager.operations.single['state'];
        report['old_fixture_removed'] =
            manager.operations.single['state'] == 'done';
        report['passed'] =
            report['reading_state_restored'] == true &&
            report['old_fixture_removed'] == true &&
            verifiedFields.every((key) => report[key] == true);
        if (report['passed'] != true) {
          fail('Replacement not yet verified; no replay.');
        }
      } catch (error) {
        try {
          await diagnose?.call();
        } catch (_) {
          report['diagnostic_available'] = false;
        }
        report['passed'] = false;
        report['error_code'] = error is KindleFailure
            ? error.code
            : 'replacement_probe';
        if (error is KindleFailure) report['http_status'] = error.status;
        fail('Replacement check failed; inspect sanitized metrics.');
      } finally {
        try {
          await persist?.call();
        } catch (_) {
          report['private_journal_saved'] = false;
        }
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
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

class _ReplacementTransport extends http.BaseClient {
  _ReplacementTransport(this.original, this.journal, this.report);
  final String original;
  final Json journal, report;
  final delegate = http.Client();
  Future<void> Function()? beforeMutation;
  Uri? uploadUri;
  int uploads = 0, deletions = 0, seeds = 0, migrations = 0;
  String get target => text(
    (journal['operations'] as List? ?? [])
        .map(object)
        .where((op) => op['kind'] == 'replace')
        .firstOrNull?['new_id'],
  );
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    final auth =
        request.method == 'POST' &&
        (uri.host == 'api.amazon.it' && uri.path == '/auth/token' ||
            uri.host == 'www.amazon.it' &&
                uri.path == '/ap/exchangetoken/cookies');
    final read =
        request.method == 'GET' &&
        (kindleAllowedUri(uri) ||
            uri.host == 'www.amazon.it' && uri.path == '/hz/mycd/myx');
    final sidecar =
        request.method == 'POST' &&
        uri.host == 'cde-ta-g7g.amazon.com' &&
        uri.path == '/FionaCDEServiceEngine/sidecar';
    final webAjax =
        request.method == 'POST' &&
        uri.host == 'www.amazon.it' &&
        uri.path == '/hz/mycd/ajax';
    var ownership = false;
    if (webAjax && request is http.Request) {
      final param = object(
        object(jsonDecode(request.bodyFields['data'] ?? '{}'))['param'],
      );
      if (param.length == 1 && param.containsKey('OwnershipData')) {
        final query = object(param['OwnershipData']);
        ownership =
            query['contentType'] == 'KindlePDoc' &&
            query['batchSize'] == 100 &&
            query['sortIndex'] == 'DATE' &&
            query['sortOrder'] == 'DESCENDING' &&
            query['startIndex'] is int &&
            (query['startIndex'] as int) >= 0 &&
            (query['startIndex'] as int) < 1000;
      }
    }
    final delete = webAjax && !ownership;
    final upload =
        request.method == 'POST' &&
            uri.host == 'kd.amazon.com' &&
            const {
              '/import/upload-url',
              '/import/kindle-doc/send-to-kindle',
            }.contains(uri.path) ||
        request.method == 'PUT' && uri == uploadUri;
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        !(auth || read || sidecar || delete || ownership || upload)) {
      throw const KindleFailure('replacement_probe_guard');
    }
    if (sidecar) {
      if (request is! http.Request) {
        throw const KindleFailure('replacement_probe_guard');
      }
      final xml = XmlDocument.parse(request.body);
      final books = xml.findAllElements('book').toList();
      if (books.length != 1 || books.single.getAttribute('type') != 'PDOC') {
        throw const KindleFailure('replacement_probe_guard');
      }
      await beforeMutation!();
      final id = books.single.getAttribute('key');
      if (id == original &&
          journal['seed_state'] == 'submitting' &&
          ++seeds == 1) {
        if (books.single.getAttribute('guid') != journal['seed_guid'] ||
            books.single.childElements.length != 2 ||
            xml.findAllElements('last_read').single.getAttribute('begin') !=
                '${journal['seed_position']}' ||
            xml.findAllElements('bookmark').single.getAttribute('begin') !=
                '${journal['seed_bookmark']}') {
          throw const KindleFailure('replacement_probe_guard');
        }
      } else if (id == target && target.isNotEmpty && ++migrations == 1) {
        final op = object((journal['operations'] as List).single);
        final plan = object(op['migration_plan']);
        if (op['state'] != 'migration_submitting' ||
            books.single.getAttribute('guid') != plan['guid'] ||
            xml.findAllElements('last_read').single.getAttribute('begin') !=
                '${plan['position']}' ||
            jsonEncode(
                  xml
                      .findAllElements('bookmark')
                      .map((m) => int.parse(m.getAttribute('begin')!))
                      .toList(),
                ) !=
                jsonEncode(plan['bookmarks'])) {
          throw const KindleFailure('replacement_probe_annotation_guard');
        }
      } else {
        throw const KindleFailure('replacement_probe_annotation_guard');
      }
      report['annotation_writes'] = seeds + migrations;
      await beforeMutation!();
    }
    if (delete) {
      if (++deletions > 1 || request is! http.Request) {
        throw const KindleFailure('replacement_probe_delete_guard');
      }
      await beforeMutation!();
      final op = object((journal['operations'] as List).single);
      if (op['state'] != 'replacement_retiring' ||
          object(op['item'])['id'] != original ||
          object(op['migration_plan'])['target'] == null) {
        throw const KindleFailure('replacement_probe_delete_guard');
      }
      final data = object(jsonDecode(request.bodyFields['data'] ?? '{}'));
      final details = object(
        object(object(data['param'])['DeleteContent'])['asinDetails'],
      );
      if (details.length != 1 ||
          details.keys.single != original ||
          object(details[original])['category'] != 'KindlePDoc') {
        throw const KindleFailure('replacement_probe_delete_guard');
      }
      report['document_deletions'] = deletions;
    }
    if (uri.path == '/import/kindle-doc/send-to-kindle') {
      if (++uploads != 1 || request is! http.Request) {
        throw const KindleFailure('replacement_probe_upload_limit');
      }
      final data = object(jsonDecode(request.body));
      final meta = object(data['documentMetadata']);
      if (meta['title'] != journal['title'] ||
          meta['author'] != 'KMReader test' ||
          meta['inputFormat'] != 'epub' ||
          data['fileSize'] != journal['size'] ||
          data['archive'] != true ||
          (data['targetDevices'] as List).isNotEmpty) {
        throw const KindleFailure('replacement_probe_upload_guard');
      }
      report['document_uploads'] = uploads;
      await beforeMutation!();
    }
    final response = await delegate.send(request);
    final steps = report['steps'] ??= <Json>[];
    (steps as List).add({
      'step': sidecar
          ? 'write_generated_state'
          : ownership
          ? 'read_cloud_ownership'
          : delete
          ? 'retire_generated_original'
          : request.method == 'PUT'
          ? 'upload_transfer'
          : uri.path.startsWith('/delivery/')
          ? 'generated_delivery'
          : uri.path,
      'http_status': response.statusCode,
    });
    if (uri.path != '/import/upload-url') return response;
    final bytes = await response.stream.toBytes();
    final value = object(jsonDecode(utf8.decode(bytes)));
    uploadUri = Uri.tryParse(text(value['uploadUrl']));
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() => delegate.close();
}
