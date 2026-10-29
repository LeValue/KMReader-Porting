import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show compute;

import 'models.dart';
import 'app_version.dart';
import 'network_preferences.dart';
import 'client_log.dart';
import 'server_event.dart';

class ApiFailure implements Exception {
  const ApiFailure(
    this.message, {
    this.status,
    this.offline = false,
    this.path,
    this.retryable = false,
  });
  final String? path;
  final String message;
  final int? status;
  final bool offline, retryable;
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
  bool authenticating = false;
  NetworkPreferences Function()? readNetworkPreferences;
  NetworkPreferences get network =>
      readNetworkPreferences?.call() ??
      const NetworkPreferences(
        request: 25,
        download: 60,
        authentication: 25,
        retries: 1,
      );
  final _transfers = <String, ({String path, Future<void> future})>{};

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
    'User-Agent': 'KMReader-Porting/$appVersion',
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
    Future<void>? abortTrigger,
    Set<int> acceptedStatuses = const {},
    Duration? responseTimeout,
  }) async {
    if (_closed) throw const ApiFailure('The server connection was closed.');
    final request = http.AbortableRequest(
      method,
      uri(path, query),
      abortTrigger: abortTrigger,
    )..followRedirects = false;
    request.headers.addAll({...headers, ...?extra});
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final response = await _client
          .send(request)
          .timeout(
            responseTimeout ??
                Duration(
                  seconds: authenticating
                      ? network.authentication
                      : network.request,
                ),
          );
      ClientLog.instance.add(
        response.statusCode >= 400 ? 'error' : 'debug',
        authenticating
            ? 'authentication'
            : path.contains('/pages/') || path.contains('/thumbnail')
            ? 'media'
            : 'api',
        '$method HTTP ${response.statusCode}',
      );
      if ((response.statusCode < 200 || response.statusCode >= 300) &&
          !acceptedStatuses.contains(response.statusCode)) {
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
          retryable: status == 429 || status >= 500,
          path: path,
        );
      }
      return response;
    } on http.RequestAbortedException {
      throw const ApiFailure('Download cancelled.');
    } on TimeoutException {
      ClientLog.instance.add('warning', 'network', 'Request timed out');
      throw ApiFailure(
        'The server took too long to respond.',
        offline: true,
        path: path,
      );
    } on SocketException {
      throw ApiFailure(
        'Unable to reach the server.',
        offline: true,
        path: path,
      );
    } on http.ClientException {
      throw ApiFailure(
        'The connection to the server was interrupted.',
        offline: true,
        retryable: true,
        path: path,
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
    final retryable =
        method == 'GET' ||
        method == 'POST' &&
            RegExp(r'^/api/v1/(books|series)/list$').hasMatch(path);
    for (var attempt = 0; ; attempt++) {
      try {
        final response = await send(
          path,
          method: method,
          body: body,
          query: query,
          extra: extra,
        );
        final bytes = await response.stream.toBytes().timeout(
          Duration(
            seconds: authenticating ? network.authentication : network.request,
          ),
        );
        if (bytes.isEmpty) return null;
        try {
          return bytes.length > 256 * 1024
              ? await compute(_decodeJson, bytes)
              : _decodeJson(bytes);
        } on FormatException {
          throw ApiFailure(
            'The server returned an unexpected response.',
            path: path,
          );
        }
      } on ApiFailure catch (error) {
        if (attempt < network.retries &&
            retryable &&
            (error.retryable || error.offline) &&
            !_closed) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          continue;
        }
        rethrow;
      } on http.ClientException {
        if (attempt < network.retries && retryable && !_closed) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          continue;
        }
        throw ApiFailure(
          'The connection to the server was interrupted.',
          offline: true,
          path: path,
        );
      } on SocketException {
        if (attempt < network.retries && retryable && !_closed) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          continue;
        }
        throw ApiFailure(
          'Unable to reach the server.',
          offline: true,
          path: path,
        );
      } on TimeoutException {
        throw ApiFailure(
          'The server took too long to respond.',
          offline: true,
          path: path,
        );
      }
    }
  }

  Future<Uint8List> bytes(String path) async {
    final result = await mediaBytes(path);
    if (result.bytes == null) {
      throw const ApiFailure('Unexpected empty image response.');
    }
    return result.bytes!;
  }

  Future<({Uint8List? bytes, String? etag, String? modified, bool notModified})>
  mediaBytes(String path, {String? etag, String? modified}) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final response = await send(
          path,
          acceptedStatuses: const {304},
          responseTimeout: Duration(seconds: network.download),
          extra: {
            'Accept': '*/*',
            if (etag != null && etag.isNotEmpty)
              'If-None-Match': etag
            else if (modified != null && modified.isNotEmpty)
              'If-Modified-Since': modified,
          },
        );
        if (response.statusCode == 304) {
          await response.stream.drain<void>();
          return (
            bytes: null,
            etag: response.headers['etag'] ?? etag,
            modified: response.headers['last-modified'] ?? modified,
            notModified: true,
          );
        }
        final bytes = await response.stream.toBytes().timeout(
          Duration(seconds: network.download),
        );
        return (
          bytes: bytes,
          etag: response.headers['etag'],
          modified: response.headers['last-modified'],
          notModified: false,
        );
      } catch (error) {
        final transient =
            error is SocketException ||
            error is HttpException ||
            error is TimeoutException ||
            (error is http.ClientException &&
                error is! http.RequestAbortedException) ||
            (error is ApiFailure &&
                (error.retryable ||
                    error.offline ||
                    (error.status ?? 0) >= 500));
        if (attempt >= network.retries || _closed || !transient) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  Future<void> download(
    String path,
    File target, {
    void Function(int, int?)? progress,
    bool Function()? cancelled,
    Future<void>? abortTrigger,
  }) {
    final key = target.absolute.path;
    final existing = _transfers[key];
    if (existing != null) {
      if (existing.path != path) {
        return Future.error(
          const ApiFailure(
            'Another resource is already being saved to this file.',
          ),
        );
      }
      return existing.future;
    }
    final future = _retryTransfer(
      path,
      target,
      progress: progress,
      cancelled: cancelled,
      abortTrigger: abortTrigger,
    ).whenComplete(() => _transfers.remove(key));
    _transfers[key] = (path: path, future: future);
    return future;
  }

  Future<void> _retryTransfer(
    String path,
    File target, {
    void Function(int, int?)? progress,
    bool Function()? cancelled,
    Future<void>? abortTrigger,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await _transfer(
          path,
          target,
          progress: progress,
          cancelled: cancelled,
          abortTrigger: abortTrigger,
        );
        return;
      } catch (error) {
        final transient =
            error is SocketException ||
            error is HttpException ||
            error is TimeoutException ||
            (error is http.ClientException &&
                error is! http.RequestAbortedException) ||
            (error is ApiFailure &&
                (error.retryable ||
                    error.offline ||
                    error.status == 408 ||
                    error.status == 429 ||
                    (error.status ?? 0) >= 500));
        if (!transient ||
            attempt >= (readNetworkPreferences == null ? 2 : network.retries) ||
            _closed ||
            cancelled?.call() == true) {
          rethrow;
        }
        // Only immutable GET transfers are retried. Their journal validates
        // retained bytes with Range/If-Range before any append.
        await Future<void>.delayed(
          Duration(milliseconds: attempt == 0 ? 200 : 800),
        );
      }
    }
  }

  Future<void> _transfer(
    String path,
    File target, {
    void Function(int, int?)? progress,
    bool Function()? cancelled,
    Future<void>? abortTrigger,
  }) async {
    if (cancelled?.call() == true || _closed) {
      throw const ApiFailure('Download cancelled.');
    }
    await target.parent.create(recursive: true);
    final partial = File('${target.path}.part'),
        metadata = File('${target.path}.part.json');
    final address = uri(path).toString();
    Json previous = {};
    try {
      if (await metadata.exists()) {
        previous = object(jsonDecode(await metadata.readAsString()));
      }
    } on FormatException {
      /* A torn journal is safely replaced by a full transfer. */
    }
    var offset = await partial.exists() ? await partial.length() : 0;
    var validator = text(previous['validator']);
    if (previous['url'] != address || validator.isEmpty) offset = 0;
    http.StreamedResponse response;
    try {
      response = await send(
        path,
        abortTrigger: abortTrigger,
        responseTimeout: Duration(seconds: network.download),
        extra: {
          'Accept': '*/*',
          if (offset > 0) 'Range': 'bytes=$offset-',
          if (offset > 0) 'If-Range': validator,
        },
      );
    } on ApiFailure catch (e) {
      if (e.status != 416 || offset == 0) rethrow;
      // A changed or shortened resource invalidates the old range.
      if (await partial.exists()) await partial.delete();
      if (await metadata.exists()) await metadata.delete();
      return _transfer(
        path,
        target,
        progress: progress,
        cancelled: cancelled,
        abortTrigger: abortTrigger,
      );
    }
    final etag = response.headers['etag'];
    final modified = response.headers['last-modified'];
    final currentValidator = etag != null && !etag.startsWith('W/')
        ? etag
        : modified ?? '';
    int? total = response.contentLength;
    if (response.statusCode == 206) {
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
          .firstMatch(response.headers['content-range'] ?? '');
      if (offset == 0 ||
          range == null ||
          int.parse(range[1]!) != offset ||
          int.parse(range[2]!) < offset ||
          int.parse(range[3]!) <= int.parse(range[2]!) ||
          response.contentLength != null &&
              response.contentLength != int.parse(range[2]!) - offset + 1 ||
          currentValidator.isNotEmpty && currentValidator != validator) {
        await response.stream.drain<void>();
        if (await partial.exists()) await partial.delete();
        if (await metadata.exists()) await metadata.delete();
        throw const ApiFailure(
          'The server returned an invalid download range. Retry the download.',
          retryable: true,
        );
      }
      total = int.parse(range[3]!);
    } else {
      // If-Range returning 200 means the resource changed or range is unsupported.
      offset = 0;
    }
    validator = currentValidator;
    await metadata.writeAsString(
      jsonEncode({'url': address, 'validator': validator}),
      flush: true,
    );
    final sink = partial.openWrite(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    var received = offset;
    var transferred = 0;
    var lastNotification = DateTime.fromMillisecondsSinceEpoch(0);
    var closed = false;
    try {
      await for (final chunk in response.stream.timeout(
        Duration(seconds: network.download),
      )) {
        if (cancelled?.call() == true || _closed) {
          throw const ApiFailure('Download cancelled.');
        }
        sink.add(chunk);
        received += chunk.length;
        transferred += chunk.length;
        if (DateTime.now().difference(lastNotification).inMilliseconds >= 100) {
          progress?.call(received, total);
          lastNotification = DateTime.now();
        }
      }
      await sink.flush();
      await sink.close();
      closed = true;
      if (cancelled?.call() == true || _closed) {
        throw const ApiFailure('Download cancelled.');
      }
      if (response.contentLength != null &&
              transferred != response.contentLength ||
          total != null && received != total) {
        throw const ApiFailure(
          'The download was incomplete. Please retry.',
          retryable: true,
        );
      }
      await partial.rename(target.path);
      if (await metadata.exists()) await metadata.delete();
      progress?.call(received, total);
    } catch (error) {
      if (!closed) await sink.close();
      // Keep the journal and partial bytes. Future retries resume only when a
      // strong ETag or Last-Modified validator makes the range safe.
      if (error is http.RequestAbortedException) {
        throw const ApiFailure('Download cancelled.');
      }
      rethrow;
    }
  }

  Stream<String> events() => serverEvents().map((event) => event.type);
  Stream<ServerEvent> serverEvents({String? lastEventId}) {
    final abort = Completer<void>();
    StreamSubscription<ServerEvent>? body;
    late StreamController<ServerEvent> controller;
    var cancelled = false, paused = false;
    Future<void> start() async {
      try {
        if (_closed) {
          await controller.close();
          return;
        }
        final response = await send(
          '/sse/v1/events',
          abortTrigger: abort.future,
          extra: {
            'Accept': 'text/event-stream',
            if (lastEventId != null &&
                lastEventId.isNotEmpty &&
                !lastEventId.contains(RegExp(r'[\r\n\x00]')))
              'Last-Event-ID': lastEventId,
          },
        );
        if (cancelled) {
          await response.stream.listen((_) {}).cancel();
          return;
        }
        body = decodeServerEvents(response.stream).listen(
          (event) {
            if (!cancelled) controller.add(event);
          },
          onError: (Object error, StackTrace stack) {
            if (!cancelled && !controller.isClosed) {
              controller.addError(error, stack);
              unawaited(controller.close());
            }
          },
          onDone: () {
            if (!cancelled && !controller.isClosed) {
              unawaited(controller.close());
            }
          },
        );
        if (paused) body!.pause();
      } catch (error, stack) {
        if (!cancelled && !controller.isClosed) {
          controller.addError(error, stack);
          await controller.close();
        }
      }
    }

    controller = StreamController<ServerEvent>(
      onListen: () => unawaited(start()),
      onPause: () {
        paused = true;
        body?.pause();
      },
      onResume: () {
        paused = false;
        body?.resume();
      },
      onCancel: () async {
        cancelled = true;
        if (!abort.isCompleted) abort.complete();
        await body?.cancel();
      },
    );
    return controller.stream;
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
      query: {'page': page, 'size': 40, 'sort': sortQuery(kind, sort)},
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
