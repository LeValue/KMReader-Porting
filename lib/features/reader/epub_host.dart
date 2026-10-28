import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

import 'epub_document.dart';

class EpubHost {
  EpubHost._(
    this.document,
    this._isolate,
    this._control,
    this._base,
    this.packagePath,
    this.identifier,
    this.language,
    this.direction,
  );
  final EpubDocument document;
  final Isolate _isolate;
  final SendPort _control;
  final String _base, packagePath, identifier, language, direction;
  Future<void>? _closing;
  Uri get base => Uri.parse(_base);
  Uri get reader => base.resolve('reader/');
  Uri get publication => base.resolve('book/${Uri(path: packagePath)}');

  static Future<EpubHost> open(
    EpubDocument document, {
    required String filePath,
  }) async {
    final assets = <String, Uint8List>{};
    for (final name in [
      'epub.min.js',
      'jszip.min.js',
      'reader.js',
      'reader.css',
    ]) {
      final data = await rootBundle.load('assets/epub/$name');
      assets[name] = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
    }
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_startEpubServer, (
      filePath,
      assets,
      ready.sendPort,
    ));
    try {
      final info =
          await ready.first.timeout(const Duration(seconds: 30)) as Map;
      if (info['error'] != null) throw FormatException(info['error'] as String);
      return EpubHost._(
        document,
        isolate,
        info['control'] as SendPort,
        info['base'] as String,
        info['package'] as String,
        info['identifier'] as String,
        info['language'] as String,
        info['direction'] as String,
      );
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      ready.close();
    }
  }

  Future<void> close() => _closing ??= _stop();
  Future<Uri> addFont(String id, Uint8List bytes) async {
    if (_closing != null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        bytes.length > 32 * 1024 * 1024) {
      throw StateError('Font unavailable.');
    }
    final reply = ReceivePort();
    _control.send(('font', (id, bytes), reply.sendPort));
    try {
      await reply.first.timeout(const Duration(seconds: 10));
    } finally {
      reply.close();
    }
    return base.resolve('fonts/$id');
  }

  Future<void> _stop() async {
    final reply = ReceivePort();
    _control.send(('close', null, reply.sendPort));
    try {
      await reply.first.timeout(const Duration(seconds: 5));
    } finally {
      reply.close();
      _isolate.kill(priority: Isolate.immediate);
    }
  }
}

Future<void> _startEpubServer(
  (String, Map<String, Uint8List>, SendPort) request,
) async {
  EpubDocument? document;
  try {
    document = EpubDocument.open(request.$1);
    final host = await _EpubResourceServer.open(document, request.$2);
    final control = ReceivePort();
    request.$3.send({
      'control': control.sendPort,
      'base': host.base.toString(),
      'package': host.packagePath,
      'identifier': host.identifier,
      'language': host.language,
      'direction': host.direction,
    });
    control.listen((dynamic message) async {
      final (command, value, reply) = message as (String, Object?, SendPort);
      if (command == 'close') {
        await host.close();
        document!.close();
        control.close();
        reply.send(true);
      }
      if (command == 'font') {
        final (id, bytes) = value as (String, Uint8List);
        host.customFonts[id] = bytes;
        reply.send(true);
      }
    });
  } catch (error) {
    document?.close();
    request.$3.send({'error': error.toString()});
  }
}

/// Serves one publication to a local browser without extracting the ZIP or
/// exposing Komga credentials. Each reader owns a loopback port and random path.
class _EpubResourceServer {
  _EpubResourceServer._(
    this.document,
    this._server,
    this._assets,
    this._token,
    this.packagePath,
    this.identifier,
    this.language,
    this.direction,
  );
  final EpubDocument document;
  final HttpServer _server;
  final Map<String, Uint8List> _assets;
  final String _token, packagePath, identifier, language, direction;
  final _fonts = <String, (List<int>, int)>{};
  final customFonts = <String, Uint8List>{};
  bool _closed = false;
  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}/$_token/');
  Uri get reader => base.resolve('reader/');
  Uri get publication =>
      base.resolve('book/${Uri(path: packagePath).toString()}');

  static Future<_EpubResourceServer> open(
    EpubDocument document,
    Map<String, Uint8List> assets,
  ) async {
    final container = XmlDocument.parse(
      EpubDocument.decodeText(document.resource('META-INF/container.xml')),
    );
    final packagePath = EpubDocument.resolve(
      'container.xml',
      container.descendants
          .whereType<XmlElement>()
          .firstWhere((e) => e.name.local == 'rootfile')
          .getAttribute('full-path')!,
    );
    final package = XmlDocument.parse(
      EpubDocument.decodeText(document.resource(packagePath)),
    );
    final elements = package.descendants.whereType<XmlElement>();
    String field(String name) =>
        elements
            .where((e) => e.name.local == name)
            .firstOrNull
            ?.innerText
            .trim() ??
        '';
    final unique = package.rootElement.getAttribute('unique-identifier');
    final identifier =
        elements
            .where(
              (e) =>
                  e.name.local == 'identifier' &&
                  (unique == null || e.getAttribute('id') == unique),
            )
            .firstOrNull
            ?.innerText
            .trim() ??
        '';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final token = base64Url
        .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    final host = _EpubResourceServer._(
      document,
      server,
      assets,
      token,
      packagePath,
      identifier,
      field('language'),
      elements
              .where((e) => e.name.local == 'spine')
              .firstOrNull
              ?.getAttribute('page-progression-direction') ??
          'ltr',
    );
    host._readFontObfuscation();
    server.listen(host._serve);
    return host;
  }

  void _readFontObfuscation() {
    if (document.archive.findFile('META-INF/encryption.xml') == null) return;
    final xml = XmlDocument.parse(
      EpubDocument.decodeText(document.resource('META-INF/encryption.xml')),
    );
    for (final data in xml.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'EncryptedData',
    )) {
      final elements = data.descendants.whereType<XmlElement>();
      final algorithm = elements
          .where((e) => e.name.local == 'EncryptionMethod')
          .firstOrNull
          ?.getAttribute('Algorithm');
      final uri = elements
          .where((e) => e.name.local == 'CipherReference')
          .firstOrNull
          ?.getAttribute('URI');
      if (uri == null) continue;
      final path = EpubDocument.resolve('container.xml', uri);
      if (algorithm == 'http://www.idpf.org/2008/embedding') {
        _fonts[path] = (
          sha1
              .convert(utf8.encode(identifier.replaceAll(RegExp(r'\s'), '')))
              .bytes,
          1040,
        );
      } else if (algorithm == 'http://ns.adobe.com/pdf/enc#RC') {
        final uuid = identifier
            .replaceFirst(RegExp(r'^urn:uuid:', caseSensitive: false), '')
            .replaceAll('-', '');
        if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(uuid)) {
          _fonts[path] = (
            [
              for (var i = 0; i < 32; i += 2)
                int.parse(uuid.substring(i, i + 2), radix: 16),
            ],
            1024,
          );
        }
      }
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Cache-Control', 'private, max-age=3600');
    response.headers.set('Referrer-Policy', 'no-referrer');
    response.headers.set(
      'Content-Security-Policy',
      "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data: blob:; connect-src 'self'; frame-src 'self' blob:; object-src 'none'; base-uri 'self'; form-action 'none'",
    );
    try {
      if (_closed ||
          !['GET', 'HEAD'].contains(request.method) ||
          request.uri.pathSegments.firstOrNull != _token) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final path = request.uri.pathSegments.skip(1).join('/');
      Uint8List bytes;
      String mime;
      if (path == 'reader/' || path == 'reader') {
        bytes = Uint8List.fromList(
          utf8.encode(
            '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1"><link rel="stylesheet" href="../vendor/reader.css"></head><body><div id="viewer"></div><script src="../vendor/jszip.min.js"></script><script src="../vendor/epub.min.js"></script><script src="../vendor/reader.js"></script></body></html>',
          ),
        );
        mime = 'text/html';
      } else if (path.startsWith('vendor/') &&
          [
            'epub.min.js',
            'jszip.min.js',
            'reader.js',
            'reader.css',
          ].contains(path.substring(7))) {
        final name = path.substring(7);
        bytes = _assets[name]!;
        mime = name.endsWith('.css') ? 'text/css' : 'application/javascript';
      } else if (path.startsWith('fonts/') &&
          customFonts.containsKey(path.substring(6))) {
        bytes = customFonts[path.substring(6)]!;
        final header = String.fromCharCodes(bytes.take(4));
        mime = switch (header) {
          'OTTO' => 'font/otf',
          'wOFF' => 'font/woff',
          'wOF2' => 'font/woff2',
          _ => 'font/ttf',
        };
      } else if (path.startsWith('book/')) {
        final resource = EpubDocument.resolve(
          'container.xml',
          Uri(path: path.substring(5)).toString(),
        );
        bytes = document.resource(resource);
        final obfuscation = _fonts[resource];
        if (obfuscation != null) {
          bytes = Uint8List.fromList(bytes);
          for (var i = 0; i < min(bytes.length, obfuscation.$2); i++) {
            bytes[i] ^= obfuscation.$1[i % obfuscation.$1.length];
          }
        }
        mime = _mime(resource);
      } else {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final charset = bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe
          ? 'utf-16le'
          : bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff
          ? 'utf-16be'
          : 'utf-8';
      response.headers.set(
        'Content-Type',
        '$mime${mime.startsWith('text/') || mime.contains('xml') || mime.contains('javascript') ? '; charset=$charset' : ''}',
      );
      response.contentLength = bytes.length;
      if (request.method == 'GET') response.add(bytes);
    } catch (_) {
      response.statusCode = HttpStatus.notFound;
    } finally {
      try {
        await response.close();
      } on SocketException {
        /* Reader closed. */
      } on HttpException {
        /* Client detached. */
      }
    }
  }

  static String _mime(String path) =>
      switch (path.split('.').last.toLowerCase()) {
        'xhtml' || 'html' || 'htm' => 'application/xhtml+xml',
        'opf' => 'application/oebps-package+xml',
        'ncx' || 'xml' => 'application/xml',
        'css' => 'text/css',
        'svg' => 'image/svg+xml',
        'png' => 'image/png',
        'jpg' || 'jpeg' => 'image/jpeg',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'woff' => 'font/woff',
        'woff2' => 'font/woff2',
        'ttf' => 'font/ttf',
        'otf' => 'font/otf',
        _ => 'application/octet-stream',
      };
  Future<void> close() async {
    _closed = true;
    await _server.close(force: true);
  }
}
