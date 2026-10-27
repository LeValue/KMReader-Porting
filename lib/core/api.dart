import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show compute;

import 'models.dart';

class ApiFailure implements Exception {
  const ApiFailure(
    this.message, {
    this.status,
    this.offline = false,
    this.path,
  });
  final String? path;
  final String message;
  final int? status;
  final bool offline;
  @override
  String toString() => message;
}

class KomgaApi {
  KomgaApi(
    this.base, {
    required this.authentication,
    required this._credential,
    http.Client? client,
  }) : _client = client ?? http.Client();
  final Uri base;
  final Authentication authentication;
  final String _credential;
  final http.Client _client;
  bool _closed = false;

  Uri uri(String path, [Map<String, dynamic>? query]) {
    if (!path.startsWith('/') || path.startsWith('//')) {
      throw ArgumentError('API path must be absolute');
    }
    final result = Uri.parse('${base.toString()}$path');
    if (result.origin != base.origin ||
        !result.path.startsWith('${base.path}/')) {
      throw ArgumentError('Request outside configured server');
    }
    return query == null
        ? result
        : result.replace(
            queryParameters: {
              for (final e in query.entries)
                if (e.value != null)
                  e.key: e.value is Iterable
                      ? (e.value as Iterable).map((v) => '$v').toList()
                      : '${e.value}',
            },
          );
  }

  Map<String, String> get headers => {
    'Accept': 'application/json',
    'User-Agent': 'KMReader-Porting/0.1',
    if (_credential.isNotEmpty)
      if (authentication == Authentication.apiKey)
        'X-API-Key': _credential
      else
        'Authorization': 'Basic $_credential',
  };

  Future<http.StreamedResponse> send(
    String path, {
    String method = 'GET',
    dynamic body,
    Map<String, dynamic>? query,
    Map<String, String>? extra,
  }) async {
    if (_closed) throw const ApiFailure('The server connection was closed.');
    final request = http.Request(method, uri(path, query))
      ..followRedirects = false;
    request.headers.addAll({...headers, ...?extra});
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 25));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        final status = response.statusCode;
        throw ApiFailure(
          switch (status) {
            401 => 'Authentication failed. Check your credentials.',
            403 => 'This account does not have permission for this action.',
            404 => 'This content is unavailable or the server does not support this feature.',
            >= 300 && < 400 =>
              'The server redirected the request. Use its final address.',
            _ => 'The server returned HTTP $status. Please try again.',
          },
          status: status,
          path: path,
        );
      }
      return response;
    } on TimeoutException {
      throw const ApiFailure(
        'The server took too long to respond.',
        offline: true,
      );
    } on SocketException {
      throw const ApiFailure('Unable to reach the server.', offline: true);
    } on http.ClientException {
      throw const ApiFailure(
        'The connection to the server was interrupted.',
        offline: true,
      );
    }
  }

  Future<dynamic> request(
    String path, {
    String method = 'GET',
    dynamic body,
    Map<String, dynamic>? query,
    Map<String, String>? extra,
  }) async {
    final response = await send(
      path,
      method: method,
      body: body,
      query: query,
      extra: extra,
    );
    final bytes = await response.stream.toBytes().timeout(
      const Duration(seconds: 30),
    );
    if (bytes.isEmpty) return null;
    try {
      return bytes.length > 256 * 1024
          ? await compute(_decodeJson, bytes)
          : _decodeJson(bytes);
    } on FormatException {
      throw const ApiFailure('The server returned an unexpected response.');
    }
  }

  Future<Uint8List> bytes(String path) async {
    final response = await send(path, extra: {'Accept': '*/*'});
    return response.stream.toBytes().timeout(const Duration(seconds: 45));
  }

  Future<void> download(
    String path,
    File target, {
    void Function(int, int?)? progress,
    bool Function()? cancelled,
  }) async {
    final response = await send(path, extra: {'Accept': '*/*'});
    await target.parent.create(recursive: true);
    final partial = File('${target.path}.part');
    final sink = partial.openWrite();
    var received = 0;
    var lastNotification = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 45),
      )) {
        if (cancelled?.call() == true || _closed) {
          throw const ApiFailure('Download cancelled.');
        }
        sink.add(chunk);
        received += chunk.length;
        if (DateTime.now().difference(lastNotification).inMilliseconds >= 100) {
          progress?.call(received, response.contentLength);
          lastNotification = DateTime.now();
        }
      }
      await sink.flush();
      await sink.close();
      if (response.contentLength != null &&
          received != response.contentLength) {
        throw const ApiFailure('The download was incomplete. Please retry.');
      }
      await partial.rename(target.path);
      progress?.call(received, response.contentLength);
    } catch (_) {
      await sink.close();
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  Stream<String> events() async* {
    final response = await send(
      '/sse/v1/events',
      extra: {'Accept': 'text/event-stream'},
    );
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (_closed) return;
      if (line.startsWith('event:')) yield line.substring(6).trim();
    }
  }

  Future<Json> user() async => object(await request('/api/v2/users/me'));
  Future<CatalogPage> catalog(
    String kind, {
    int page = 0,
    String? search,
    String sort = 'metadata.titleSort,asc',
    Json? condition,
    String? path,
  }) async => CatalogPage.parse(
    kind,
    await request(
      path ?? '/api/v1/$kind/list',
      method: path == null ? 'POST' : 'GET',
      body: path == null
          ? {
              'condition': ?condition,
              if (search != null && search.isNotEmpty) 'fullTextSearch': search,
            }
          : null,
      query: {'page': page, 'size': 40, 'sort': sort},
    ),
  );
  Future<Book> book(String id) async =>
      Book(object(await request('/api/v1/books/${Uri.encodeComponent(id)}')));
  void close() {
    _closed = true;
    _client.close();
  }
}

dynamic _decodeJson(Uint8List bytes) => jsonDecode(utf8.decode(bytes));
