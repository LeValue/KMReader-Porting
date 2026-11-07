import 'dart:async';
import 'dart:io';

import '../models.dart';
import 'client.dart';

/// Capability protected loopback bridge. Signing stays in the app; the worker
/// can only request bounded ranges of these specific manifest resources.
class KindleCoverProxy {
  KindleCoverProxy._(this.server, this.client, this.resources, this.headers);
  final HttpServer server;
  final KindleClient client;
  final List<List<Uri>> resources;
  final Map<String, String> headers;
  final token = kindleRandom(24);
  int _transferred = 0;
  static Future<KindleCoverProxy> open(
    KindleClient client,
    Json manifest,
    Map<String, String> headers,
  ) async {
    final resources = <List<Uri>>[];
    for (final part in (manifest['resources'] as List).map(object)) {
      if (!const {
        'KINDLE_MAIN_BASE',
        'KINDLE_MAIN_METADATA',
        'KINDLE_MAIN_ATTACHABLE',
      }.contains(part['type'])) {
        continue;
      }
      final urls = <Uri>[];
      for (final (key, field) in [
        ('optimalEndpoint', 'directUrl'),
        ('endpoint', 'url'),
      ]) {
        final endpoint = object(part[key]);
        final uri = Uri.tryParse(text(endpoint[field]));
        if (uri == null || !kindleAllowedUri(uri) || urls.contains(uri)) {
          continue;
        }
        if (text(endpoint['httpMethod'], text(endpoint['method'], 'GET')) ==
            'GET') {
          urls.add(uri);
        }
      }
      if (urls.isNotEmpty) resources.add(urls);
      if (resources.length == 6) break;
    }
    final proxy = KindleCoverProxy._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      client,
      resources,
      headers,
    );
    proxy.server.listen((request) => unawaited(proxy._serve(request)));
    return proxy;
  }

  List<String> get urls => List.generate(
    resources.length,
    (index) => 'http://127.0.0.1:${server.port}/kindle-cover/$token/$index',
  );
  Future<void>? _closing;
  Future<void> close() => _closing ??= server.close(force: true).then((_) {});
  Future<void> _serve(HttpRequest incoming) async {
    try {
      final parts = incoming.uri.pathSegments;
      final index = parts.length == 3 ? int.tryParse(parts[2]) : null;
      final range = incoming.headers.value('range') ?? '';
      final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
      if (incoming.method != 'GET' ||
          parts.length != 3 ||
          parts[0] != 'kindle-cover' ||
          parts[1] != token ||
          index == null ||
          index < 0 ||
          index >= resources.length ||
          match == null ||
          int.parse(match[2]!) < int.parse(match[1]!) ||
          int.parse(match[2]!) - int.parse(match[1]!) >= 256 * 1024 ||
          _transferred >= 4 * 1024 * 1024) {
        incoming.response.statusCode = 403;
        return;
      }
      for (final url in resources[index]) {
        final upstream = await (() async {
          try {
            return await client.request(
              url,
              headers: {
                ...headers,
                'Range': range,
                'Accept-Encoding': 'identity',
              },
            );
          } on KindleFailure {
            return null;
          }
        })();
        if (upstream == null) continue;
        if (upstream.statusCode != 200 && upstream.statusCode != 206) {
          await upstream.stream.listen(null).cancel();
          continue;
        }
        if (upstream.statusCode == 200 &&
            (upstream.contentLength == null ||
                upstream.contentLength! > 4 * 1024 * 1024 - _transferred)) {
          await upstream.stream.listen(null).cancel();
          continue;
        }
        incoming.response.statusCode = upstream.statusCode;
        for (final header in [
          'content-length',
          'content-range',
          'content-type',
          'etag',
          'last-modified',
          'content-encoding',
        ]) {
          if (upstream.headers[header] case final String value) {
            incoming.response.headers.set(header, value);
          }
        }
        await for (final chunk in upstream.stream.timeout(
          const Duration(seconds: 25),
        )) {
          _transferred += chunk.length;
          if (_transferred > 4 * 1024 * 1024) {
            throw const KindleFailure('cover_size');
          }
          incoming.response.add(chunk);
        }
        return;
      }
      incoming.response.statusCode = 502;
    } catch (_) {
      try {
        incoming.response.statusCode = 502;
      } catch (_) {}
    } finally {
      try {
        await incoming.response.close();
      } catch (_) {}
    }
  }
}
