part of 'import.dart';

/// First-party web STK authenticated from this reader's existing refresh token.
/// No browser cookies, extra OAuth login or Firs registration are required.
class _KindleWebsiteImporter {
  _KindleWebsiteImporter(this.owner);
  final KindleImporter owner;
  final _cookies = <String, String>{};
  String? _csrf;
  DateTime? _csrfAt;
  Future<void>? _connecting;
  bool _authenticated = false;
  static const _host = 'www.amazon.it';
  static const _version = '2.1.1.7';

  void _cookie(String name, String value) {
    if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name) &&
        !RegExp(r'[;\r\n\x00]').hasMatch(value)) {
      _cookies[name] = value;
    }
  }

  bool _domain(String domain) => const {
    '.amazon.it',
    'amazon.it',
    '.www.amazon.it',
    'www.amazon.it',
  }.contains(domain);

  Future<List<int>> _request(
    String path,
    KindleImportCancellation cancel, {
    Json? form,
    Json? json,
    bool csrf = false,
  }) async {
    cancel.check();
    final request = http.AbortableRequest(
      form != null || json != null ? 'POST' : 'GET',
      Uri.https(_host, path),
      abortTrigger: cancel.future,
    )..followRedirects = false;
    request.headers.addAll({
      'User-Agent': 'Mozilla/5.0',
      'Accept': 'application/json',
      if (_cookies.isNotEmpty)
        'Cookie': _cookies.entries.map((c) => '${c.key}=${c.value}').join('; '),
      if (csrf) 'anti-csrftoken-a2z': _csrf!,
      if (json != null) 'Origin': 'https://$_host',
      if (json != null) 'Referer': 'https://$_host/sendtokindle',
    });
    if (form != null) {
      request.bodyFields = form.map((k, v) => MapEntry(k, '$v'));
    }
    if (json != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(json);
    }
    return owner._send(
      request,
      cancel,
      onResponse: (response) {
        final setCookie = response.headers['set-cookie'];
        if (setCookie == null) return;
        for (final entry in setCookie.split(RegExp(r',(?=\s*[^=;, ]+=)'))) {
          try {
            final cookie = Cookie.fromSetCookieValue(entry);
            if (cookie.domain == null || _domain(cookie.domain!)) {
              _cookie(cookie.name, cookie.value);
            }
          } on FormatException {
            /* Ignore malformed optional cookies. */
          }
        }
      },
    );
  }

  Json _decode(List<int> bytes) {
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>) throw const FormatException();
      if (value['success'] == false ||
          value['statusCode'] != null && value['statusCode'] != 0) {
        throw const KindleFailure('import_rejected');
      }
      return value;
    } on KindleFailure {
      rethrow;
    } catch (_) {
      throw const KindleFailure('import_response');
    }
  }

  Future<void> _connect(KindleImportCancellation cancel) async {
    _cookies.clear();
    final current = owner.client.session;
    if (current == null) throw const KindleFailure('not_connected');
    final response = _decode(
      await _request(
        '/ap/exchangetoken/cookies',
        cancel,
        form: {
          'app_name': 'Kindle for iOS',
          'app_version': kindleAppVersion,
          'source_token': text(current.json['refresh_token']),
          'source_token_type': 'refresh_token',
          'requested_token_type': 'auth_cookies',
          'domain': '.amazon.it',
        },
      ),
    );
    final raw = object(
      object(object(response['response'])['tokens'])['cookies'],
    );
    for (final entry in raw.entries) {
      if (!_domain(entry.key)) continue;
      for (final cookie in (entry.value as List? ?? []).map(object)) {
        _cookie(text(cookie['Name']), text(cookie['Value']));
      }
    }
    if (_cookies.isEmpty) throw const KindleFailure('import_web_authorization');
    final auth = _decode(
      await _request('/sendtokindle/extension/checkAuth', cancel),
    );
    if (auth['isAuthed'] != true) {
      throw const KindleFailure('import_web_authorization');
    }
    _authenticated = true;
  }

  Future<void> _ensure(KindleImportCancellation cancel) async {
    if (!_authenticated) {
      final work = _connecting ??= _stage(
        'web_authentication',
        () => _connect(cancel),
      );
      try {
        await work;
      } finally {
        _connecting = null;
      }
    }
    if (_csrfAt != null && DateTime.now().difference(_csrfAt!).inSeconds < 50) {
      return;
    }
    await _stage('web_csrf', () async {
      final html = utf8.decode(await _request('/sendtokindle/empty', cancel));
      final value = html_parser
          .parse(html)
          .querySelector('input[name="csrfToken"]')
          ?.attributes['value'];
      if (value == null || value.isEmpty) {
        throw const KindleFailure('import_web_authorization');
      }
      _csrf = value;
      _csrfAt = DateTime.now();
    });
  }

  Future<Json> _post(
    String path,
    Json body,
    String stage,
    KindleImportCancellation cancel,
  ) async {
    await _ensure(cancel);
    return _stage(
      stage,
      () async => _decode(
        await _request('/sendtokindle/$path', cancel, json: body, csrf: true),
      ),
    );
  }

  Future<List<KindleImportDevice>> devices(
    KindleImportCancellation cancel,
  ) async {
    final value = await _post(
      'get-device-list',
      {'extName': 'chrome_ocs', 'extVersion': '1.0'},
      'devices',
      cancel,
    );
    if (value['ownedDevices'] is! List) {
      throw const KindleFailure('import_response', stage: 'devices');
    }
    return [
      for (final item in (value['ownedDevices'] as List).map(object))
        if (text(item['deviceSerialNumber']).isNotEmpty)
          KindleImportDevice(
            text(item['deviceSerialNumber']),
            text(item['deviceName'], 'Kindle'),
          ),
    ];
  }

  Future<String> upload(
    XFile file, {
    required String title,
    required String author,
    required List<String> targets,
    required KindleImportCancellation cancel,
    void Function(int, int)? onProgress,
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
    if (title.trim().isEmpty || title.length > 250 || author.length > 250) {
      throw const KindleFailure('import_metadata');
    }
    final result = await _post(
      'init',
      {
        'extName': 'chrome_ocs',
        'appVersion': _version,
        'fileSize': size,
        'fileExtension': format,
      },
      'upload_url',
      cancel,
    );
    final uri = Uri.tryParse(text(result['uploadUrl']));
    final token = text(result['stkToken']);
    if (uri == null || !kindleAllowedUri(uri) || token.isEmpty) {
      throw const KindleFailure('delivery_address');
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
      ..contentLength = size
      ..headers['Content-Type'] = '';
    await _stage('transfer', () => owner._send(request, cancel));
    cancel.check();
    // Renew expired CSRF BEFORE declaring a delivery submission.
    await _ensure(cancel);
    cancel.check();
    onSubmitting?.call();
    const mime = {
      'epub': 'application/epub+zip',
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'txt': 'text/plain',
      'rtf': 'application/rtf',
      'htm': 'text/html',
      'html': 'text/html',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'bmp': 'image/bmp',
    };
    Json accepted;
    try {
      accepted = await _post(
        'send-v2',
        {
          'extName': 'chrome_ocs',
          'extVersion': _version,
          'inputFormat': format,
          'stkToken': token,
          'title': title.trim(),
          'author': author.trim(),
          'dataType': mime[format],
          'archive': true,
          'deviceList': <String>[],
          'fileSize': size,
          'inputFileName': '${title.trim()}.$format',
          'batchId': kindleRandom(),
        },
        'delivery',
        cancel,
      );
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
