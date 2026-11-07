import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../models.dart';
import 'client.dart';

const kindleImportExtensions = [
  'epub',
  'pdf',
  'doc',
  'docx',
  'txt',
  'rtf',
  'htm',
  'html',
  'jpg',
  'jpeg',
  'png',
  'gif',
  'bmp',
];
const kindleImportMaxBytes = 200 * 1024 * 1024;

class KindleImportCancellation {
  final _abort = Completer<void>();
  bool get cancelled => _abort.isCompleted;
  Future<void> get future => _abort.future;
  void cancel() {
    if (!cancelled) _abort.complete();
  }

  void check() {
    if (cancelled) throw const KindleFailure('import_cancelled');
  }
}

class KindleImportDevice {
  const KindleImportDevice(this.serial, this.name);
  final String serial, name;
}

/// Local files -> Amazon's archived personal documents. No Komga server upload.
/// Protocol reference and verification limits: docs/KINDLE_IMPORT.md.
class KindleImporter {
  KindleImporter(this.client);
  final KindleClient client;
  Future<Json>? _registering;
  static const _clientInfo = {
    'appName': 'ShellExtension',
    'appVersion': '1.1.1.253',
    'os': 'MacOSX_10.14.6_x64',
    'osArchitecture': 'x64',
  };

  Future<List<int>> _send(
    http.BaseRequest request,
    KindleImportCancellation cancel,
  ) async {
    cancel.check();
    try {
      final response = await client
          .importRequest(request)
          .timeout(
            const Duration(seconds: 90),
            onTimeout: () {
              cancel.cancel();
              throw const KindleFailure('import_network');
            },
          );
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 90),
      )) {
        cancel.check();
        if (bytes.length + chunk.length > 1024 * 1024) {
          throw const KindleFailure('response_size');
        }
        bytes.addAll(chunk);
      }
      cancel.check();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw KindleFailure('import_rejected', status: response.statusCode);
      }
      return bytes;
    } on KindleFailure {
      rethrow;
    } catch (_) {
      cancel.check();
      throw const KindleFailure('import_network');
    }
  }

  Future<Json> _device(KindleImportCancellation cancel) async {
    await client.refresh();
    cancel.check();
    final saved = object(client.session!.json['send_device']);
    if (text(saved['adp_token']).isNotEmpty &&
        text(saved['device_private_key']).isNotEmpty) {
      return saved;
    }
    if (_registering != null) return _registering!;
    final work = () async {
      final fields = {
        'deviceType': 'A1K6D1WRW0MALS',
        'deviceSerialNumber': kindleRandom(24)
            .replaceAll('-', 'A')
            .replaceAll('_', 'B')
            .toUpperCase(),
        'pid': 'D21NN3GG',
        'authToken': text(client.session!.json['access_token']),
        'authTokenType': 'AccessToken',
        'softwareVersion': '253',
        'os_version': 'MacOSX_10.14.6_x64',
        'device_model': 'KMReader Send to Kindle',
      };
      // Use XML nodes to escape tokens without interpolating them into markup.
      final xml = XmlElement(XmlName.parts('request'), [], [
        XmlElement(XmlName.parts('parameters'), [], [
          for (final entry in fields.entries)
            XmlElement(XmlName.parts(entry.key), [], [XmlText(entry.value)]),
        ]),
      ]);
      final request =
          http.AbortableRequest(
              'POST',
              Uri.https(
                'firs-ta-g7g.amazon.com',
                '/FirsProxy/registerDeviceWithToken',
              ),
              abortTrigger: cancel.future,
            )
            ..followRedirects = false
            ..headers.addAll({
              'Content-Type': 'text/xml',
              'User-Agent': 'Mozilla/5.0',
              'Accept-Language': 'en-US,*',
            })
            ..body = xml.toXmlString();
      final bytes = await _send(request, cancel);
      // Keep parser and private response off the UI isolate.
      final device = await compute(_parseImportDevice, bytes);
      cancel.check();
      await client.saveImportDevice({
        ...device,
        'serial': fields['deviceSerialNumber'],
      });
      return device;
    }();
    _registering = work;
    try {
      return await work;
    } finally {
      _registering = null;
    }
  }

  Future<Json> _post(
    String path,
    Json data,
    KindleImportCancellation cancel,
  ) async {
    final device = await _device(cancel);
    final body = jsonEncode({'clientInfo': _clientInfo, ...data});
    final headers = await compute(kindleImportSigningHeaders, (
      device,
      path,
      body,
      null,
    ));
    cancel.check();
    final request =
        http.AbortableRequest(
            'POST',
            Uri.https('kd.amazon.com', path),
            abortTrigger: cancel.future,
          )
          ..followRedirects = false
          ..headers.addAll({
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'User-Agent': 'Mozilla/5.0',
            'Accept-Language': 'en-US,*',
            ...headers,
          })
          ..body = body;
    final bytes = await _send(request, cancel);
    try {
      final value = object(jsonDecode(utf8.decode(bytes)));
      if (value['statusCode'] != 0) {
        throw const KindleFailure('import_rejected');
      }
      return value;
    } on FormatException {
      throw const KindleFailure('import_response');
    }
  }

  Future<List<KindleImportDevice>> devices(
    KindleImportCancellation cancel,
  ) async {
    final result = await _post(
      '/import/kindle-doc/get-device-list',
      {},
      cancel,
    );
    if (result['ownedDevices'] is! List) {
      throw const KindleFailure('import_response');
    }
    return [
      for (final value in result['ownedDevices'])
        if (text(object(value)['deviceSerialNumber']).isNotEmpty)
          KindleImportDevice(
            text(object(value)['deviceSerialNumber']),
            text(object(value)['deviceName'], 'Kindle'),
          ),
    ];
  }

  Future<String> upload(
    XFile file, {
    required String title,
    required String author,
    required List<String> targets,
    required KindleImportCancellation cancel,
    void Function(int sent, int total)? onProgress,
    void Function()? onSubmitting,
  }) async {
    cancel.check();
    final format = p.extension(file.name).replaceFirst('.', '').toLowerCase();
    if (!kindleImportExtensions.contains(format)) {
      throw const KindleFailure('import_format');
    }
    final size = await file.length();
    if (size <= 0 || size > kindleImportMaxBytes) {
      throw const KindleFailure('import_size');
    }
    if (title.trim().isEmpty ||
        title.length > 250 ||
        author.length > 250 ||
        targets.isEmpty) {
      throw const KindleFailure('import_metadata');
    }
    final result = await _post('/import/upload-url', {
      'fileSize': size,
    }, cancel);
    final uri = Uri.tryParse(text(result['uploadUrl']));
    final token = text(result['stkToken']);
    // Presigned upload destinations receive file bytes, never ADP credentials.
    if (uri == null || !kindleAllowedUri(uri) || token.isEmpty) {
      throw const KindleFailure('delivery_address');
    }
    final expiry = result['expiryTime'];
    if (expiry is num && expiry > 0) {
      final milliseconds = expiry < 100000000000 ? expiry * 1000 : expiry;
      if (milliseconds <= DateTime.now().millisecondsSinceEpoch) {
        throw const KindleFailure('import_expired');
      }
    }
    var sent = 0;
    final clock = Stopwatch()..start();
    Stream<List<int>> contents() async* {
      await for (final chunk in file.openRead()) {
        cancel.check();
        sent += chunk.length;
        if (sent > size) throw const KindleFailure('import_changed');
        yield chunk;
        if (clock.elapsedMilliseconds >= 100 || sent == size) {
          onProgress?.call(sent, size);
          clock.reset();
        }
      }
      if (sent != size) throw const KindleFailure('import_changed');
    }

    final request = _ImportStreamRequest(uri, contents(), cancel.future)
      ..contentLength = size;
    await _send(request, cancel);
    cancel.check();
    onSubmitting?.call();
    // Delivery is a single mutation. A lost reply must never trigger a replay.
    Json accepted;
    try {
      accepted = await _post('/import/kindle-doc/send-to-kindle', {
        'documentMetadata': {
          'author': author.trim(),
          'crc32': 0,
          'inputFormat': format,
          'title': title.trim(),
        },
        'archive': true,
        'fileSize': size,
        'forceConvert': false,
        'sendTimeMillis': DateTime.now().millisecondsSinceEpoch,
        'shouldExtractWebContent': false,
        'stkToken': token,
        'targetDevices': targets,
      }, cancel);
    } on KindleFailure catch (error) {
      if (error.code == 'import_rejected' &&
          (error.status == null || error.status! < 500)) {
        rethrow;
      }
      throw const KindleFailure('import_delivery_uncertain');
    }
    final sku = text(accepted['sku']);
    if (sku.isEmpty) throw const KindleFailure('import_delivery_uncertain');
    return sku;
  }
}

class _ImportStreamRequest extends http.BaseRequest with http.Abortable {
  _ImportStreamRequest(Uri uri, this.contents, this.abortTrigger)
    : super('PUT', uri) {
    followRedirects = false;
  }
  final Stream<List<int>> contents;
  @override
  final Future<void> abortTrigger;
  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(contents);
  }
}

Json _parseImportDevice(List<int> bytes) {
  try {
    final xml = XmlDocument.parse(utf8.decode(bytes));
    String value(String name) =>
        xml.findAllElements(name).firstOrNull?.innerText.trim() ?? '';
    final result = {
      'adp_token': value('adp_token'),
      'device_private_key': value('device_private_key'),
    };
    if (result.values.any((v) => v.isEmpty)) {
      throw const KindleFailure('import_registration');
    }
    return result;
  } on KindleFailure {
    rethrow;
  } catch (_) {
    throw const KindleFailure('import_registration');
  }
}
