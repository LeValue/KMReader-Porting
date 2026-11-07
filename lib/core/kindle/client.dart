import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' as pc;
import 'package:xml/xml.dart';

import '../models.dart';
import 'catalog_filter.dart';

const kindleDeviceType = 'AGZZ1ST63LKBW';
const kindleAppVersion = '6.38.0.100';
const kindleSoftwareVersion = '1184366692';
const kindleUserAgent = 'Kindle/1.0.235280.0.10 CFNetwork/1220.1 Darwin/20.3.0';
const kindleCatalogUrl =
    'https://todo-ta-g7g.amazon.com/FionaTodoListProxy/syncMetaData';
const _signedHosts = {
  'todo-ta-g7g.amazon.com',
  'kindle-digital-delivery.amazon.com',
  'cde-ta-g7g.amazon.com',
};

class KindleFailure implements Exception {
  const KindleFailure(this.code, {this.status});
  final String code;
  final int? status;
  @override
  String toString() =>
      status == null ? 'Kindle: $code' : 'Kindle: $code (HTTP $status)';
}

String kindleRandom([int count = 32]) => base64UrlEncode(
  List<int>.generate(count, (_) => Random.secure().nextInt(256)),
).replaceAll('=', '');

class KindleLoginAttempt {
  KindleLoginAttempt({required this.serial, String? verifier, String? state})
    : verifier = verifier ?? kindleRandom(),
      state = state ?? kindleRandom();
  final String serial, verifier, state;
  String get clientId => utf8
      .encode('$serial#$kindleDeviceType')
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  Uri get url => Uri.https('www.amazon.it', '/ap/signin', {
    'openid.return_to': 'https://www.amazon.it/ap/maplanding',
    'openid.assoc_handle': 'amzn_device_it',
    'openid.identity': 'http://specs.openid.net/auth/2.0/identifier_select',
    'openid.claimed_id': 'http://specs.openid.net/auth/2.0/identifier_select',
    'openid.mode': 'checkid_setup',
    'openid.ns': 'http://specs.openid.net/auth/2.0',
    'openid.ns.oa2': 'http://www.amazon.com/ap/ext/oauth/2',
    'openid.ns.pape': 'http://specs.openid.net/extensions/pape/1.0',
    'openid.pape.max_auth_age': '0',
    'openid.oa2.client_id': 'device:$clientId',
    'openid.oa2.scope': 'device_auth_access',
    'openid.oa2.response_type': 'code',
    'openid.oa2.state': state,
    'pageId': 'amzn_device_common_dark',
    'accountStatusPolicy': 'P1',
    'openid.oa2.code_challenge_method': 'S256',
    'openid.oa2.code_challenge': base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', ''),
  });
  static bool isCallback(Uri uri) =>
      uri.scheme == 'https' &&
      const {'www.amazon.it', 'amazon.it'}.contains(uri.host) &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      uri.path == '/ap/maplanding';
  Json? callback(Uri uri) {
    if (!isCallback(uri)) return null;
    final values = <String, List<String>>{};
    try {
      for (final field in '${uri.query}&${uri.fragment}'.split('&')) {
        final equals = field.indexOf('=');
        if (equals < 0) continue;
        final key = Uri.decodeComponent(field.substring(0, equals));
        final value = Uri.decodeComponent(field.substring(equals + 1));
        (values[key] ??= []).add(value);
      }
    } on FormatException {
      throw const KindleFailure('login_callback');
    }
    if (values.containsKey('error') || values.containsKey('openid.oa2.error')) {
      throw const KindleFailure('login_rejected');
    }
    final echoed = values['openid.oa2.state'] ?? values['state'];
    if (echoed != null && (echoed.length != 1 || echoed.single != state)) {
      throw const KindleFailure('login_state');
    }
    final code = values['openid.oa2.authorization_code'];
    if (code == null) return null;
    if (code.length != 1 ||
        code.single.isEmpty ||
        RegExp(r'\s|\x00').hasMatch(code.single)) {
      throw const KindleFailure('login_callback');
    }
    return {
      'client_id': clientId,
      'authorization_code': code.single,
      'code_verifier': verifier,
      'code_algorithm': 'SHA-256',
      'client_domain': 'DeviceLegacy',
    };
  }
}

class KindleSession {
  KindleSession(Json data) : json = Map<String, dynamic>.from(data) {
    if (json['marketplace'] != 'amazon.it' ||
        [
          'serial',
          'device_type',
          'customer_id',
          'access_token',
          'refresh_token',
          'adp_token',
          'device_private_key',
        ].any((key) => json[key] is! String || (json[key] as String).isEmpty) ||
        json['expires'] is! num) {
      throw const KindleFailure('session_invalid');
    }
  }
  final Json json;
  String get id =>
      'kindle-it-${sha256.convert(utf8.encode('amazon.it\u0000${json['customer_id']}')).toString().substring(0, 32)}';
  @override
  String toString() => 'KindleSession(amazon.it)';
}

bool kindleAllowedUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.port == 443 &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment &&
    const [
      'amazon.com',
      'amazon.it',
      'amazonaws.com',
      'cloudfront.net',
      'media-amazon.com',
      'images-amazon.com',
      'ssl-images-amazon.com',
    ].any((suffix) => uri.host == suffix || uri.host.endsWith('.$suffix'));

// Minimal DER reader for PKCS#1 / PKCS#8 RSA private keys. No key material is
// included in exceptions, diagnostics, URLs or command-line arguments.
class _Der {
  _Der(this.bytes);
  final Uint8List bytes;
  int offset = 0;
  (int, Uint8List) next() {
    if (offset + 2 > bytes.length) throw const FormatException();
    final tag = bytes[offset++];
    var length = bytes[offset++];
    if (length & 128 != 0) {
      final count = length & 127;
      if (count == 0 || count > 4 || offset + count > bytes.length) {
        throw const FormatException();
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = length * 256 + bytes[offset++];
      }
    }
    if (offset + length > bytes.length) throw const FormatException();
    final data = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return (tag, data);
  }
}

pc.RSAPrivateKey _privateKey(String key) {
  try {
    final binary = base64Decode(
      key.replaceAll(RegExp(r'-----[^-]+-----|\s'), ''),
    );
    var (tag, value) = _Der(Uint8List.fromList(binary)).next();
    if (tag != 48) throw const FormatException();
    var contents = _Der(value);
    final version = contents.next();
    if (version.$1 != 2) throw const FormatException();
    var modulus = contents.next();
    if (modulus.$1 == 48) {
      final wrapped = contents.next();
      if (wrapped.$1 != 4) throw const FormatException();
      final inner = _Der(wrapped.$2).next();
      if (inner.$1 != 48) throw const FormatException();
      contents = _Der(inner.$2);
      contents.next();
      modulus = contents.next();
    }
    BigInt integer((int, Uint8List) entry) {
      if (entry.$1 != 2 || entry.$2.isEmpty) throw const FormatException();
      return entry.$2.fold(
        BigInt.zero,
        (value, byte) => (value << 8) | BigInt.from(byte),
      );
    }

    final n = integer(modulus);
    integer(contents.next()); // public exponent
    final d = integer(contents.next()),
        p = integer(contents.next()),
        q = integer(contents.next());
    return pc.RSAPrivateKey(n, d, p, q);
  } catch (_) {
    throw const KindleFailure('device_key');
  }
}

Map<String, String> kindleSigningHeaders({
  required Uri uri,
  required KindleSession session,
  String method = 'GET',
  List<int> body = const [],
  String? timestamp,
}) {
  timestamp ??= '${DateTime.now().toUtc().toIso8601String().split('.').first}Z';
  final serialized = uri.toString();
  final authorityEnd = serialized.indexOf('/', serialized.indexOf('://') + 3);
  final target = authorityEnd < 0
      ? '/${uri.hasQuery ? '?${uri.query}' : ''}'
      : serialized.substring(authorityEnd);
  final message = <int>[
    ...utf8.encode('$method\n$target\n$timestamp\n'),
    ...body,
    ...utf8.encode('\n${session.json['adp_token']}'),
  ];
  final signer = pc.RSASigner(pc.SHA256Digest(), '0609608648016503040201')
    ..init(
      true,
      pc.PrivateKeyParameter<pc.RSAPrivateKey>(
        _privateKey(session.json['device_private_key']),
      ),
    );
  final signature = signer.generateSignature(Uint8List.fromList(message));
  return {
    'x-adp-token': session.json['adp_token'],
    'x-adp-alg': 'SHA256withRSA:1.0',
    'x-adp-signature': '${base64Encode(signature.bytes)}:$timestamp',
  };
}

/// Send to Kindle uses raw SHA-256 inside PKCS#1 padding, unlike CDE requests.
Map<String, String> kindleImportSigningHeaders(
  (Json, String, String, String?) args,
) {
  final (device, path, body, suppliedTime) = args;
  final time =
      suppliedTime ??
      '${DateTime.now().toUtc().toIso8601String().split('.').first}Z';
  final digest = sha256.convert(
    utf8.encode('POST\n$path\n$time\n$body\n${device['adp_token']}'),
  );
  final signer = pc.PKCS1Encoding(pc.RSAEngine())
    ..init(
      true,
      pc.PrivateKeyParameter<pc.RSAPrivateKey>(
        _privateKey(device['device_private_key']),
      ),
    );
  final signature = signer.process(Uint8List.fromList(digest.bytes));
  return {
    'X-ADP-Authentication-Token': device['adp_token'],
    'X-ADP-Request-Digest': '${base64Encode(signature)}:$time',
  };
}

class KindleClient {
  KindleClient({http.Client? client, this.session, this.saveSession})
    : _http = client ?? http.Client();
  final http.Client _http;
  KindleSession? session;
  final Future<void> Function(KindleSession)? saveSession;
  Future<void>? _refreshing;
  bool _closed = false;
  // The importer supplies its own bounded, abortable requests. No redirect or
  // automatic mutation retry is added here; closing an account closes them too.
  Future<http.StreamedResponse> importRequest(http.BaseRequest request) {
    if (_closed) throw const KindleFailure('connection_closed');
    return _http.send(request);
  }

  Future<void> saveImportDevice(Json device) async {
    if (_closed || session == null) {
      throw const KindleFailure('connection_closed');
    }
    final updated = KindleSession({...session!.json, 'send_device': device});
    await saveSession?.call(updated);
    if (_closed) throw const KindleFailure('connection_closed');
    session = updated;
  }

  void close() {
    _closed = true;
    _http.close();
  }

  Future<Uint8List> _bounded(
    http.StreamedResponse response, {
    int limit = 16 * 1024 * 1024,
  }) async {
    final chunks = BytesBuilder(copy: false);
    try {
      await for (final bytes in response.stream.timeout(
        const Duration(seconds: 60),
      )) {
        if (chunks.length + bytes.length > limit) {
          throw const KindleFailure('response_size');
        }
        chunks.add(bytes);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw KindleFailure('amazon_request', status: response.statusCode);
      }
      return chunks.takeBytes();
    } on KindleFailure {
      rethrow;
    } catch (_) {
      throw const KindleFailure('network');
    }
  }

  Future<Json> _auth(String path, Json data, {bool form = false}) async {
    final request = http.Request('POST', Uri.https('api.amazon.it', path))
      ..followRedirects = false;
    request.headers.addAll({
      'User-Agent': kindleUserAgent,
      'Accept-Language': 'it-IT',
    });
    if (form) {
      request.bodyFields = data.map((key, value) => MapEntry(key, '$value'));
    } else {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(data);
    }
    try {
      final response = await _http
          .send(request)
          .timeout(const Duration(seconds: 60));
      final bytes = await _bounded(response);
      return object(jsonDecode(utf8.decode(bytes)));
    } on KindleFailure {
      rethrow;
    } catch (_) {
      throw const KindleFailure('authentication_response');
    }
  }

  Future<KindleSession> register(
    KindleLoginAttempt attempt,
    Json authorization,
  ) async {
    final data = await _auth('/auth/register', {
      'requested_token_type': [
        'bearer',
        'mac_dms',
        'website_cookies',
        'store_authentication_cookie',
      ],
      'cookies': {'website_cookies': [], 'domain': '.amazon.it'},
      'registration_data': {
        'domain': 'Device',
        'app_name': 'Kindle for iOS',
        'app_version': kindleAppVersion,
        'device_type': kindleDeviceType,
        'device_serial': attempt.serial,
        'device_name': '%FIRST_NAME%%FIRST_NAME_POSSESSIVE_STRING%%DUPE_STRATEGY_1ST%KMReader',
        'device_model': 'iPhone',
        'os_version': '14.4',
        'software_version': kindleSoftwareVersion,
      },
      'auth_data': authorization,
      'requested_extensions': ['device_info', 'customer_info'],
    });
    final success = object(object(data['response'])['success']);
    final tokens = object(success['tokens']);
    final bearer = object(tokens['bearer']), adp = object(tokens['mac_dms']);
    final customer = object(object(success['extensions'])['customer_info']);
    final result = KindleSession({
      'marketplace': 'amazon.it',
      'profile': 'kindle-device-it-pkce-v1',
      'serial': attempt.serial,
      'device_type': kindleDeviceType,
      'customer_id': customer['user_id'] ?? customer['customer_id'],
      'flow': 'pkce',
      'access_token': bearer['access_token'],
      'refresh_token': bearer['refresh_token'],
      'expires':
          DateTime.now().millisecondsSinceEpoch / 1000 +
          integer(bearer['expires_in']),
      'adp_token': adp['adp_token'],
      'device_private_key': adp['device_private_key'],
    });
    if (_closed) throw const KindleFailure('connection_closed');
    session = result;
    await saveSession?.call(result);
    return result;
  }

  Future<void> refresh() async {
    final current = session;
    if (_closed || current == null) throw const KindleFailure('not_connected');
    if ((current.json['expires'] as num) >
        DateTime.now().millisecondsSinceEpoch / 1000 + 60) {
      return;
    }
    if (_refreshing != null) return _refreshing;
    final work = () async {
      final data = await _auth('/auth/token', {
        'app_name': 'Kindle for iOS',
        'app_version': kindleAppVersion,
        'source_token_type': 'refresh_token',
        'source_token': current.json['refresh_token'],
        'requested_token_type': 'access_token',
      }, form: true);
      if (_closed) throw const KindleFailure('connection_closed');
      final updated = KindleSession({
        ...session!.json,
        'access_token': data['access_token'],
        'expires':
            DateTime.now().millisecondsSinceEpoch / 1000 +
            integer(data['expires_in']),
      });
      await saveSession?.call(updated);
      session = updated;
    }();
    _refreshing = work;
    try {
      await work;
    } finally {
      _refreshing = null;
    }
  }

  Future<http.StreamedResponse> request(
    Uri uri, {
    String method = 'GET',
    List<int> body = const [],
    Map<String, String> headers = const {},
    Future<void>? abortTrigger,
  }) async {
    await refresh();
    for (var redirects = 0; redirects < 6; redirects++) {
      if (!kindleAllowedUri(uri)) throw const KindleFailure('delivery_address');
      final request = http.AbortableRequest(
        method,
        uri,
        abortTrigger: abortTrigger,
      )..followRedirects = false;
      request.headers['User-Agent'] = kindleUserAgent;
      if (_signedHosts.contains(uri.host)) {
        request.headers.addAll(headers);
        request.bodyBytes = body;
        final activeSession = session!;
        final requestUri = uri;
        request.headers.addAll(
          await compute(_signRequest, (
            requestUri,
            activeSession.json,
            method,
            body,
          )),
        );
      } else {
        for (final entry in headers.entries) {
          if (const {'range', 'if-range'}.contains(entry.key.toLowerCase())) {
            request.headers[entry.key] = entry.value;
          } else if (entry.key.toLowerCase() == 'accept-encoding' &&
              entry.value == 'identity') {
            request.headers[entry.key] = 'identity';
          }
        }
      }
      http.StreamedResponse response;
      try {
        response = await _http
            .send(request)
            .timeout(const Duration(seconds: 60));
      } catch (_) {
        throw const KindleFailure('network');
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location'];
        await response.stream.drain<void>();
        if (location == null || method != 'GET') {
          throw const KindleFailure('redirect');
        }
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        throw KindleFailure('amazon_request', status: response.statusCode);
      }
      return response;
    }
    throw const KindleFailure('redirects');
  }

  Future<Uint8List> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async => _bounded(await request(uri, headers: headers));
  Future<Json> catalog({Json? previous, bool full = false}) async {
    final incremental =
        !full &&
        previous?['complete'] == true &&
        text(previous?['sync_time']).isNotEmpty;
    final bytes = await get(
      Uri.parse(kindleCatalogUrl).replace(
        queryParameters: {
          'item_count': '10000',
          if (incremental) 'last_sync_time': text(previous?['sync_time']),
        },
      ),
    );
    return compute(_mergeKindleCatalog, (bytes, previous, incremental));
  }

  Future<(Json, Map<String, String>)> manifest(Json item) async {
    final kind = item['type'] == 'PDOC' ? 'pdoc' : 'ebook';
    final headers = <String, String>{
      'X-ADP-AttemptCount': '1',
      'X-ADP-Transport': 'WiFi',
      'X-ADP-Reason': 'ArchivedItems',
      'Accept-Language': 'it-IT',
      'X-ADP-SW': kindleSoftwareVersion,
      'x-amzn-accept-type': 'application/x.amzn.digital.deliverymanifest@1.0',
      'X-ADP-CorrelationId':
          'Device:${session?.json['device_type']}:${session?.json['serial']};kindle.${item['type']}:${item['id']}:${DateTime.now().millisecondsSinceEpoch}',
    };
    final bytes = await get(
      Uri.parse(
        'https://kindle-digital-delivery.amazon.com/delivery/manifest/kindle.$kind/${Uri.encodeComponent(text(item['id']))}',
      ),
      headers: headers,
    );
    Json data;
    try {
      data = object(jsonDecode(utf8.decode(bytes)));
    } catch (_) {
      throw const KindleFailure('manifest_shape');
    }
    if (data['resources'] is! List ||
        (data['resources'] as List).isEmpty ||
        object(data['content'])['id'] != null &&
            object(data['content'])['id'] != item['id']) {
      throw const KindleFailure('manifest_shape');
    }
    return (data, headers);
  }

  Future<Json?> sidecar(
    Json item, {
    String? guid,
    bool annotations = false,
  }) async {
    final bytes = await get(
      Uri.https('cde-ta-g7g.amazon.com', '/FionaCDEServiceEngine/sidecar', {
        'type': text(item['type']),
        'key': text(item['id']),
        if (guid != null && guid.isNotEmpty) 'guid': guid,
      }),
    );
    if (bytes.isEmpty) return null;
    try {
      return await compute(_readSidecar, (bytes, annotations));
    } catch (_) {
      throw const KindleFailure('sidecar_shape');
    }
  }

  Future<Json> pushPosition(
    Json item,
    String guid,
    int position, {
    bool annotations = false,
  }) async {
    if (guid.isEmpty || position < 0) {
      throw const KindleFailure('position_invalid');
    }
    final timestamp =
        '${DateTime.now().toUtc().toIso8601String().split('.').first}+0000';
    String attribute(String value) =>
        XmlAttribute(XmlName.parts('v'), value).toXmlString().substring(2);
    final body =
        '<annotations version="1.0" timestamp=${attribute(timestamp)}><book key=${attribute(text(item['id']))} type=${attribute(text(item['type']))} guid=${attribute(guid)}><last_read begin="$position" pos="$position" timestamp=${attribute(timestamp)}/></book></annotations>';
    final response = await request(
      Uri.https('cde-ta-g7g.amazon.com', '/FionaCDEServiceEngine/sidecar', {
        'type': text(item['type']),
      }),
      method: 'POST',
      body: utf8.encode(body),
      headers: {'Content-Type': 'application/xml'},
    );
    await _bounded(response);
    final after = await sidecar(item, guid: guid, annotations: annotations);
    final records = (after?['records'] as List? ?? []).map(object);
    final confirmed = records
        .where((record) => record['type'] == 'kindle.most_recent_read')
        .firstOrNull;
    if (after == null ||
        num.tryParse('${confirmed?['location']}') != position ||
        after['guid'] != guid) {
      throw const KindleFailure('position_not_confirmed');
    }
    return after;
  }
}

Json parseKindleCatalog(List<int> bytes) {
  XmlDocument document;
  try {
    document = XmlDocument.parse(utf8.decode(bytes));
  } catch (_) {
    throw const KindleFailure('catalog_xml');
  }
  final response = document.rootElement.name.local == 'response'
      ? document.rootElement
      : document.rootElement.childElements
            .where((e) => e.name.local == 'response')
            .firstOrNull;
  if (response == null ||
      !response.childElements.any((e) => e.name.local == 'add_update_list')) {
    throw const KindleFailure('catalog_shape');
  }
  String value(XmlElement element, String name) =>
      element.childElements
          .where((e) => e.name.local == name)
          .firstOrNull
          ?.innerText
          .trim() ??
      '';
  final items = <Json>[], removed = <Json>[];
  var count = 0;
  for (final group in response.childElements) {
    if (group.name.local == 'add_update_list') {
      for (final element in group.childElements) {
        if (element.name.local != 'meta_data') continue;
        count++;
        final id = value(element, 'ASIN'),
            type = value(element, 'cde_contenttype');
        if (id.isEmpty || !const {'PDOC', 'EBOK'}.contains(type)) continue;
        final tags = element.childElements
            .where((e) => e.name.local == 'content_tags')
            .expand((group) => group.descendants.whereType<XmlText>())
            .expand(
              (part) => part.value.toUpperCase().split(RegExp(r'[\s,;|]+')),
            )
            .toSet();
        final dictionary =
            tags.contains('DICT') ||
            tags.contains('DICTIONARY') ||
            tags.contains('FREE_DICT') ||
            ['is_dictionary', 'isDictionary'].any(
              (key) => const {
                'true',
                '1',
              }.contains(value(element, key).toLowerCase()),
            );
        final purchased = element.descendants.whereType<XmlElement>().any(
          (e) =>
              e.name.local == 'origin' &&
              value(e, 'type').toLowerCase() == 'purchase',
        );
        items.add({
          'key': '$type:$id',
          'id': id,
          'type': type,
          'title': value(element, 'title').isEmpty
              ? id
              : value(element, 'title'),
          'authors': element.descendants
              .whereType<XmlElement>()
              .where((e) => e.name.local == 'author')
              .map((e) => e.innerText.trim())
              .where((v) => v.isNotEmpty)
              .toList(),
          'is_dictionary': dictionary,
          'revision': value(element, 'content_version').isEmpty
              ? value(element, 'version')
              : value(element, 'content_version'),
          'publication_date': value(element, 'publication_date'),
          'is_amazon_dictionary':
              type == 'EBOK' &&
              dictionary &&
              (tags.contains('FREE_DICT') || !purchased),
        });
      }
    }
    if (const {
      'delete_list',
      'remove_list',
      'removal_list',
    }.contains(group.name.local)) {
      for (final element in group.childElements) {
        final id = value(element, 'ASIN').isEmpty
            ? element.innerText.trim()
            : value(element, 'ASIN');
        if (id.isNotEmpty) {
          removed.add({'id': id, 'type': value(element, 'cde_contenttype')});
        }
      }
    }
  }
  final paging =
      [
        'has_more',
        'has_more_items',
        'more',
        'truncated',
        'next_token',
        'next_page_token',
      ].any(
        (name) => !const {
          '',
          'false',
          '0',
          'no',
        }.contains(value(response, name).toLowerCase()),
      );
  return {
    'items': items,
    'removed': removed,
    'sync_time': value(response, 'sync_time'),
    'full_response': response.getAttribute('syncType')?.toLowerCase() == 'full',
    'complete': !paging && count < 10000,
  };
}

Map<String, String> _signRequest((Uri, Json, String, List<int>) value) =>
    kindleSigningHeaders(
      uri: value.$1,
      session: KindleSession(value.$2),
      method: value.$3,
      body: value.$4,
    );

Json _readSidecar((Uint8List, bool) input) {
  final root = object(jsonDecode(utf8.decode(input.$1)));
  final payload = object(root['payload'] ?? root);
  return {
    for (final key in ['guid', 'acr', 'syncToken']) key: text(payload[key]),
    'annotations_loaded': input.$2,
    'records': [
      for (final record in (payload['records'] as List? ?? []).map(object))
        if (const {
          'kindle.most_recent_read',
          'kindle.lpr',
        }.contains(record['type']))
          {
            for (final key in [
              'type',
              'location',
              'creationTime',
              'lastModificationTime',
            ])
              if (record[key] != null) key: record[key],
          }
        else if (input.$2 &&
            const {
              'kindle.bookmark',
              'kindle.highlight',
              'kindle.note',
            }.contains(record['type']) &&
            text(record['annotationId']).isNotEmpty &&
            int.tryParse('${record['startPosition']}') != null &&
            int.parse('${record['startPosition']}') >= 0)
          record,
    ],
  };
}

Json _mergeKindleCatalog((Uint8List, Json?, bool) input) {
  final (bytes, previous, incremental) = input;
  final parsed = parseKindleCatalog(bytes);
  final items = <String, Json>{
    if (incremental && parsed['full_response'] != true)
      for (final item in (previous?['items'] as List? ?? []).map(object))
        text(item['key']): item,
  };
  for (final removed in (parsed['removed'] as List).map(object)) {
    items.removeWhere(
      (_, item) =>
          item['id'] == removed['id'] &&
          (text(removed['type']).isEmpty || item['type'] == removed['type']),
    );
  }
  for (final item in (parsed['items'] as List).map(object)) {
    items[text(item['key'])] = item;
  }
  final ordered =
      items.values.where((item) => !isKindleDictionary(item)).toList()..sort(
        (a, b) =>
            text(a['title'])
                .toLowerCase()
                .compareTo(text(b['title']).toLowerCase()),
      );
  return {
    'schema': 1,
    'marketplace': 'amazon.it',
    'fetched_at': DateTime.now().toUtc().toIso8601String(),
    'sync_time': parsed['sync_time'],
    'complete': parsed['complete'],
    'items': ordered,
  };
}
