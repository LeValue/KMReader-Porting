import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/import.dart';
import 'package:kmreader/core/models.dart';

void main() {
  final path = Platform.environment['KMREADER_KINDLE_WEB_PRIVATE_SESSION'];
  test(
    'personal website STK uses existing account and a generated EPUB only',
    () async {
      final report = <String, dynamic>{
        'schema': 1,
        'document_uploads': 0,
        'document_deletions': 0,
        'annotation_writes': 0,
      };
      final upload =
          Platform.environment['KMREADER_KINDLE_PROBE_UPLOAD_FIXTURE'] ==
          'true';
      final root = Directory.systemTemp.createTempSync('kmreader-web-fixture-');
      KindleClient? client;
      try {
        final file = File(path!);
        final payload = object(jsonDecode(await file.readAsString()));
        var operation = object(payload['probe_operation']);
        Future<void> seal() async {
          payload['probe_operation'] = operation;
          await file.writeAsString(jsonEncode(payload));
          final result = await Process.run('python', [
            '-m',
            'tool.kindle_send_probe_bridge',
            'seal',
            file.path,
          ]);
          if (result.exitCode != 0) {
            throw const KindleFailure('probe_private_journal');
          }
        }

        final transport = _WebProbeClient(report, upload, () => operation);
        client = KindleClient(
          session: KindleSession(object(payload['session'])),
          client: transport,
          saveSession: (value) async {
            payload['session'] = value.json;
            await file.writeAsString(jsonEncode(payload));
          },
        );
        final importer = KindleImporter(client);
        report['device_count'] = (await importer.devices(
          KindleImportCancellation(),
        )).length;
        // A new importer must reuse the same reader account without an OAuth/Firs call.
        await KindleImporter(client).devices(KindleImportCancellation());
        report['reopened_without_browser'] = true;
        if (upload &&
            (operation.isEmpty || operation['state'] == 'preflight_failed')) {
          final title =
              'KMReader test ${DateTime.now().toUtc().millisecondsSinceEpoch}';
          operation = {'title': title, 'state': 'upload_pending'};
          final archive = Archive();
          archive.addFile(
            ArchiveFile.string('mimetype', 'application/epub+zip')
              ..compression = CompressionType.none,
          );
          for (final entry in {
            'META-INF/container.xml': '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
            'book.opf':
                '<?xml version="1.0"?><package version="3.0" unique-identifier="uid" xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:kmreader:test:${kindleRandom()}</dc:identifier><dc:title>$title</dc:title><dc:creator>KMReader test</dc:creator><dc:language>it</dc:language><meta property="dcterms:modified">2026-11-08T00:00:00Z</meta></metadata><manifest><item id="page" href="page.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="page"/></spine></package>',
            'page.xhtml':
                '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>$title</title></head><body><h1>Documento sintetico KMReader</h1><p>Questo file contiene soltanto testo generato per verificare Invio a Kindle. Non contiene libri o dati personali.</p></body></html>',
            'nav.xhtml': '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Indice</title></head><body><nav epub:type="toc"><ol><li><a href="page.xhtml">Prova</a></li></ol></nav></body></html>',
          }.entries) {
            archive.addFile(ArchiveFile.string(entry.key, entry.value));
          }
          final document = File('${root.path}/synthetic.epub');
          await document.writeAsBytes(ZipEncoder().encode(archive));
          operation['size'] = await document.length();
          await seal(); // Durable BEFORE any potential delivery submission.
          var submitted = false;
          try {
            final sku = await importer.upload(
              XFile(document.path),
              title: title,
              author: 'KMReader test',
              targets: [],
              cancel: KindleImportCancellation(),
              onSubmitting: () => submitted = true,
            );
            operation.addAll({'state': 'accepted', 'sku': sku});
            report['importer_accepted'] = true;
          } on KindleFailure catch (error) {
            operation['state'] = submitted ? 'uncertain' : 'preflight_failed';
            report['importer_accepted'] = false;
            report['error_code'] = error.code;
            report['error_stage'] = error.stage;
            report['http_status'] = error.status;
          }
          await seal();
        }
        if (operation.isNotEmpty && operation['state'] != 'preflight_failed') {
          for (var i = 0; i < 10; i++) {
            final catalog = await client.catalog(full: true);
            final matches = (catalog['items'] as List? ?? [])
                .map(object)
                .where(
                  (item) =>
                      item['type'] == 'PDOC' &&
                      item['title'] == operation['title'],
                )
                .toList();
            if (matches.length == 1) {
              report['fixture_visible_in_catalog'] = true;
              operation['catalog_id'] = matches.single['id'];
              await seal();
              break;
            }
            await Future<void>.delayed(const Duration(seconds: 5));
          }
          report['fixture_visible_in_catalog'] ??= false;
          report['fixture_state'] = operation['state'];
        }
        report['passed'] =
            report['error_code'] == null &&
            (!upload || report['fixture_visible_in_catalog'] == true);
        if (report['passed'] != true) {
          fail('Web STK fixture check failed; inspect sanitized metrics.');
        }
      } catch (error) {
        report['passed'] = false;
        report['error_code'] ??= error is KindleFailure
            ? error.code
            : 'web_probe';
        if (error is KindleFailure) {
          report['error_stage'] = error.stage;
          report['http_status'] = error.status;
        }
        fail('Web STK check failed; inspect sanitized metrics.');
      } finally {
        client?.close();
        await root.delete(recursive: true);
        final output = Platform.environment['KMREADER_KINDLE_WEB_PROBE_REPORT'];
        if (output != null) {
          await File(output).writeAsString(jsonEncode(report));
        }
      }
    },
    skip: path == null || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

class _WebProbeClient extends http.BaseClient {
  _WebProbeClient(this.report, this.upload, this.operation);
  final Json report;
  final bool upload;
  final Json Function() operation;
  final delegate = http.Client();
  Uri? uploadUri;
  int deliveries = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url;
    final web = url.host == 'www.amazon.it';
    final get =
        request.method == 'GET' &&
        (web &&
                const [
                  '/sendtokindle/extension/checkAuth',
                  '/sendtokindle/empty',
                ].contains(url.path) ||
            url.host == 'todo-ta-g7g.amazon.com' &&
                url.path == '/FionaTodoListProxy/syncMetaData');
    final auth =
        request.method == 'POST' &&
        (web &&
                const [
                  '/ap/exchangetoken/cookies',
                  '/sendtokindle/get-device-list',
                ].contains(url.path) ||
            url.host == 'api.amazon.it' && url.path == '/auth/token');
    final write =
        upload &&
        (request.method == 'POST' &&
                web &&
                const [
                  '/sendtokindle/init',
                  '/sendtokindle/send-v2',
                ].contains(url.path) ||
            request.method == 'PUT' && url == uploadUri);
    if (url.scheme != 'https' ||
        url.port != 443 ||
        url.userInfo.isNotEmpty ||
        !(get || auth || write)) {
      throw const KindleFailure('web_probe_guard');
    }
    if (url.path == '/sendtokindle/send-v2') {
      if (++deliveries > 1 || request is! http.Request) {
        throw const KindleFailure('web_probe_delivery_limit');
      }
      final body = object(jsonDecode(request.body));
      if (body['title'] != operation()['title'] ||
          body['author'] != 'KMReader test' ||
          body['inputFormat'] != 'epub' ||
          body['fileSize'] != operation()['size']) {
        throw const KindleFailure('web_probe_document_guard');
      }
      report['document_uploads'] = deliveries;
    }
    final response = await delegate.send(request);
    final requests = report['requests'] ??= <Json>[];
    final step = <String, dynamic>{
      'step': request.method == 'PUT' ? 'upload_transfer' : url.path,
      'http_status': response.statusCode,
    };
    if (response.statusCode >= 300 && response.statusCode < 400) {
      final location = Uri.tryParse(response.headers['location'] ?? '');
      step['redirect_host'] =
          const {'www.amazon.it', 'www.amazon.com'}.contains(location?.host)
          ? location!.host
          : 'other';
      step['redirect_path'] =
          const {
            '/ap/signin',
            '/sendtokindle',
            '/sendtokindle/get-device-list',
            '/sendtokindle/login',
          }.contains(location?.path)
          ? location!.path
          : 'other';
    }
    (requests as List).add(step);
    if (!const [
      '/sendtokindle/init',
      '/sendtokindle/send-v2',
    ].contains(url.path)) {
      return response;
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 90),
    )) {
      if (bytes.length + chunk.length > 1024 * 1024) {
        throw const KindleFailure('response_size');
      }
      bytes.addAll(chunk);
    }
    Json value = {};
    try {
      value = object(jsonDecode(utf8.decode(bytes)));
    } catch (_) {
      /* No raw response logging. */
    }
    if (url.path.endsWith('/init')) {
      uploadUri = Uri.tryParse(text(value['uploadUrl']));
    }
    if (url.path.endsWith('/send-v2')) {
      operation()['response'] = value; // Local DPAPI journal only.
      const fields = {
        'sku',
        'asin',
        'documentId',
        'status',
        'statusCode',
        'success',
        'message',
        'error',
        'errorCode',
        'batchId',
        'requestId',
        'results',
        'items',
      };
      report['delivery'] = {
        'http_status': response.statusCode,
        'fields': fields.where(value.containsKey).toList()..sort(),
        'other_fields': value.keys.where((k) => !fields.contains(k)).length,
      };
    }
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() => delegate.close();
}
