import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kmreader/core/kindle/client.dart';
import 'package:kmreader/core/kindle/import.dart';
import 'package:kmreader/core/models.dart';

import 'support/kindle_registration_metrics.dart';

/// Opt-in, real-account registration and device discovery. No document writes.
void main() {
  final path = Platform.environment['KMREADER_KINDLE_SEND_PRIVATE_SESSION'];
  test(
    'personal STK registration and persisted credential reuse',
    () async {
      final report = <String, dynamic>{
        'schema': 1,
        'document_uploads': 0,
        'document_deletions': 0,
        'annotation_writes': 0,
      };
      KindleClient? client;
      final transport = _ProbeClient(report);
      try {
        final file = File(path!);
        Future<void> save(KindleSession value) =>
            file.writeAsString(jsonEncode({'session': value.json}));
        client = KindleClient(
          session: KindleSession(
            object(object(jsonDecode(await file.readAsString()))['session']),
          ),
          client: transport,
          saveSession: save,
        );
        final devices = await KindleImporter.legacy(client)
            .devices(KindleImportCancellation());
        report['device_count'] = devices.length;
        final registrations = transport.registrations;
        // Reconstruct from persisted IPC, just as a new app/account session does.
        final restored = KindleClient(
          session: KindleSession(
            object(object(jsonDecode(await file.readAsString()))['session']),
          ),
          client: transport,
          saveSession: save,
        );
        await KindleImporter.legacy(restored)
            .devices(KindleImportCancellation());
        report['reused_without_registration'] =
            transport.registrations == registrations;
        expect(report['reused_without_registration'], true);
        report['passed'] = true;
      } catch (error) {
        report['passed'] = false;
        if (error is KindleFailure) {
          report['error_code'] = error.code;
          report['error_stage'] = error.stage;
          report['http_status'] = error.status;
        } else {
          report['error_code'] = 'send_probe';
        }
        fail('STK check failed; inspect the fixed-vocabulary report.');
      } finally {
        client?.close();
        transport.close();
        final output =
            Platform.environment['KMREADER_KINDLE_SEND_PROBE_REPORT'];
        if (output != null) {
          await File(output).writeAsString(jsonEncode(report));
        }
      }
    },
    skip: path == null || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

class _ProbeClient extends http.BaseClient {
  _ProbeClient(this.report);
  final Map<String, dynamic> report;
  final delegate = http.Client();
  int registrations = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url;
    final registration =
        url.host == 'firs-ta-g7g.amazon.com' &&
        url.path == '/FirsProxy/registerDeviceWithToken';
    final allowed =
        url.scheme == 'https' &&
        url.port == 443 &&
        url.userInfo.isEmpty &&
        url.query.isEmpty &&
        request.method == 'POST' &&
        (registration ||
            url.host == 'api.amazon.it' && url.path == '/auth/token' ||
            url.host == 'kd.amazon.com' &&
                url.path == '/import/kindle-doc/get-device-list');
    if (!allowed) throw const KindleFailure('send_probe_guard');
    if (registration && ++registrations > 1) {
      throw const KindleFailure('send_probe_registration_limit');
    }
    if (registration &&
        Platform.environment['KMREADER_KINDLE_PROBE_XML_DECLARATION'] ==
            'true') {
      if (request is! http.Request) {
        throw const KindleFailure('send_probe_envelope');
      }
      request.body = '<?xml version="1.0" encoding="UTF-8"?>\n${request.body}';
      report['xml_declaration_added_by_probe'] = true;
    }
    final response = await delegate.send(request);
    if (!registration) return response;
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 90),
    )) {
      if (bytes.length + chunk.length > 1024 * 1024) {
        throw const KindleFailure('response_size');
      }
      bytes.addAll(chunk);
    }
    report['registration'] = {
      'http_status': response.statusCode,
      ...kindleRegistrationMetrics(bytes),
    };
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() => delegate.close();
}
