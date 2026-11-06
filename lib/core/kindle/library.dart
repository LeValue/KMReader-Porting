import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../models.dart';
import '../store.dart';
import '../../features/reader/epub_document.dart';
import '../../features/reader/epub_page_index.dart';
import 'client.dart';
import 'conversion.dart';
import 'cover_proxy.dart';

class KindleLibrary {
  KindleLibrary({
    required this.client,
    required this.store,
    required this.directory,
    required this.profile,
    KindlePreparation? preparation,
  }) : preparation = preparation ?? NativeKindlePreparation();
  final KindleClient client;
  final LocalStore store;
  final Directory directory;
  final ServerProfile profile;
  final KindlePreparation preparation;
  void Function(String id)? onPrepared;
  Future<void>? _refreshing;
  Json? _snapshot;
  List<Json>? _visibleItems;
  Map<String, Json>? _byId;
  final _manifests =
      <String, ({DateTime time, Future<(Json, Map<String, String>)> value})>{};
  final _covers = <String, Future<File?>>{};
  final _coverFailures = <String, DateTime>{};
  final _preparing = <String, Future<File>>{};
  Json get snapshot =>
      _snapshot ??= object(store.cached(profile.id, 'kindle:catalog'));
  bool get hasCatalog => snapshot['items'] is List;
  List<Json> get items {
    if (_visibleItems == null) {
      _visibleItems = (snapshot['items'] as List? ?? [])
          .map(object)
          .where((item) => item['is_amazon_dictionary'] != true)
          .toList();
      _byId = {for (final item in _visibleItems!) idFor(item): item};
    }
    return _visibleItems!;
  }

  String idFor(Json item) =>
      sha256.convert(utf8.encode(text(item['key']))).toString();
  Json item(String id) {
    items;
    return _byId![id] ?? (throw const KindleFailure('book_unavailable'));
  }

  Json bookJson(Json item) {
    final id = idFor(item);
    final existing = object(store.cached(profile.id, 'book:$id'));
    final format =
        store.setting<String>('kindleFormat:${profile.id}:$id') ?? 'epub';
    return {
      'id': id,
      'libraryId': item['type'] == 'PDOC' ? 'kindle-documents' : 'kindle-books',
      'name': '${item['title']}.$format',
      'fileHash': text(item['revision']),
      'created': item['publication_date'],
      'lastModified': item['revision'],
      'metadata': {
        'title': item['title'],
        'titleSort': item['title'],
        'releaseDate': item['publication_date'],
        'language': '',
        'authors': [
          for (final author in item['authors'] as List? ?? [])
            {'name': author, 'role': 'writer'},
        ],
      },
      'media': {
        'mediaProfile': format.toUpperCase(),
        'status': 'READY',
        'mediaType': format == 'pdf'
            ? 'application/pdf'
            : 'application/epub+zip',
        'pagesCount': integer(object(existing['media'])['pagesCount']),
        if (object(existing['media'])['pagesCountEstimated'] == true)
          'pagesCountEstimated': true,
      },
      if (existing['readProgress'] != null)
        'readProgress': existing['readProgress'],
      'source': 'kindle',
      'kindleType': item['type'],
    };
  }

  void index() {
    final fingerprint = sha256
        .convert(utf8.encode(jsonEncode({'schema': 2, 'snapshot': snapshot})))
        .toString();
    if (store.setting<String>('kindleIndex:${profile.id}') == fingerprint) {
      return;
    }
    final books = [
      for (final item in items) CatalogItem('books', bookJson(item)),
    ];
    store.cacheBooks(profile.id, books);
    final active = books.map((book) => book.id).toSet();
    final obsolete = store.db
        .select(
          "SELECT id FROM catalog_records WHERE server=? AND kind='books'",
          [profile.id],
        )
        .map((row) => row['id'] as String)
        .where((id) => !active.contains(id))
        .toList();
    for (final id in obsolete) {
      store.offlineCatalog.remove(profile.id, 'books', id);
    }
    store.setSetting('kindleIndex:${profile.id}', fingerprint);
  }

  Future<void> refresh({bool full = false}) async {
    if (_refreshing != null) return _refreshing;
    final work = () async {
      final next = await client.catalog(
        previous: hasCatalog ? snapshot : null,
        full: full,
      );
      store.cache(profile.id, 'kindle:catalog', next);
      _snapshot = next;
      _visibleItems = null;
      index();
    }();
    _refreshing = work;
    try {
      await work;
    } finally {
      _refreshing = null;
    }
  }

  File coverFile(String id) =>
      File(p.join(directory.path, profile.id, 'kindle-covers', '$id.cover'));

  Future<(Json, Map<String, String>)> _manifest(String id) async {
    final old = _manifests[id];
    if (old != null &&
        DateTime.now().difference(old.time) < const Duration(minutes: 10)) {
      return old.value;
    }
    if (_manifests.length >= 24) _manifests.remove(_manifests.keys.first);
    final future = client.manifest(item(id));
    _manifests[id] = (time: DateTime.now(), value: future);
    try {
      return await future;
    } catch (_) {
      _manifests.remove(id);
      rethrow;
    }
  }

  void updatePages(String id, int pages, {bool estimated = true}) {
    if (pages < 1 || pages > 1000000) return;
    final old = object(store.cached(profile.id, 'book:$id'));
    if (integer(object(old['media'])['pagesCount']) == pages &&
        object(old['media'])['pagesCountEstimated'] == estimated) {
      return;
    }
    final value = old.isEmpty ? bookJson(item(id)) : old;
    store.cacheBooks(profile.id, [
      CatalogItem('books', {
        ...value,
        'media': {
          ...object(value['media']),
          'pagesCount': pages,
          'pagesCountEstimated': estimated,
        },
      }),
    ]);
    onPrepared?.call(id);
  }

  Future<File?> cover(String id) async {
    final file = coverFile(id);
    final exists = await file.exists();
    if (exists &&
        integer(
              object(
                object(store.cached(profile.id, 'book:$id'))['media'],
              )['pagesCount'],
            ) >
            0) {
      return file;
    }
    if (store.setting<bool>('kindleCovers:${profile.id}') == false ||
        store.setting<bool>('offline:${profile.id}') == true ||
        preparation is! KindleCoverPreparation) {
      return exists ? file : null;
    }
    final failed = _coverFailures[id];
    if (failed != null &&
        DateTime.now().difference(failed) < const Duration(minutes: 5)) {
      return exists ? file : null;
    }
    if (_covers[id] case final Future<File?> pending) {
      return exists ? file : await pending;
    }
    final work = () async {
      KindleCoverProxy? proxy;
      try {
        final (manifest, headers) = await _manifest(id);
        proxy = await KindleCoverProxy.open(client, manifest, headers);
        final result = await (preparation as KindleCoverPreparation).cover(
          proxy.urls,
        );
        final encoded = text(result['image']);
        if (integer(result['pages']) > 0) {
          updatePages(
            id,
            integer(result['pages']),
            estimated: result['estimated'] != false,
          );
        }
        if (encoded.isEmpty || encoded.length > 768 * 1024) return null;
        final bytes = base64Decode(encoded);
        if (bytes.length < 3 ||
            bytes[0] != 0xff ||
            bytes[1] != 0xd8 ||
            bytes[2] != 0xff) {
          return null;
        }
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        return file;
      } catch (_) {
        return null;
      } finally {
        await proxy?.close();
      }
    }();
    final tracked = work
        .then((value) {
          if (value == null) _coverFailures[id] = DateTime.now();
          return value;
        })
        .whenComplete(() {
          _covers.remove(id);
        });
    _covers[id] = tracked;
    if (exists) {
      unawaited(tracked);
      return file;
    }
    return tracked;
  }

  Directory get _preparedDirectory =>
      Directory(p.join(directory.path, profile.id, 'kindle-prepared'));
  File _preparedFile(String id) {
    final version = sha256
        .convert(utf8.encode('$id:${item(id)['revision']}:mapped-v2'))
        .toString();
    return File(p.join(_preparedDirectory.path, '$version.document'));
  }

  Future<void> clearPreparedCache() async {
    if (_preparing.isNotEmpty) {
      throw const KindleFailure('preparation_in_progress');
    }
    if (await _preparedDirectory.exists()) {
      await _preparedDirectory.delete(recursive: true);
    }
  }

  Future<File> download(
    String id,
    File target, {
    void Function(int, int?)? progress,
    bool Function()? cancelled,
    Future<void>? abortTrigger,
  }) async {
    final cached = _preparedFile(id);
    if (!await cached.exists() || await cached.length() == 0) {
      final pending = _preparing[id];
      if (pending != null) {
        await pending;
      } else {
        final work = _prepare(
          id,
          cached,
          progress: progress,
          cancelled: cancelled,
          abortTrigger: abortTrigger,
        );
        _preparing[id] = work;
        try {
          await work;
        } finally {
          _preparing.remove(id);
        }
      }
    }
    if (cancelled?.call() == true) throw const KindleFailure('cancelled');
    await target.parent.create(recursive: true);
    final partial = File('${target.path}.kindle.part');
    try {
      await cached.copy(partial.path);
      if (cancelled?.call() == true) throw const KindleFailure('cancelled');
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      final size = await target.length();
      progress?.call(size, size);
      return target;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<File> _prepare(
    String id,
    File target, {
    void Function(int, int?)? progress,
    bool Function()? cancelled,
    Future<void>? abortTrigger,
  }) async {
    final selected = item(id);
    void check() {
      if (cancelled?.call() == true) throw const KindleFailure('cancelled');
    }

    check();
    Json manifest;
    Map<String, String> headers;
    try {
      final result = await _manifest(id);
      manifest = result.$1;
      headers = result.$2;
    } on KindleFailure catch (error) {
      if (selected['type'] != 'PDOC' || error.status != 404) rethrow;
      manifest = {
        'resources': [
          {
            'id': 'legacy',
            'type': 'KINDLE_MAIN_BASE',
            'requirement': 'REQUIRED',
            'endpoint': {
              'url': Uri.https(
                'cde-ta-g7g.amazon.com',
                '/FionaCDEServiceEngine/FSDownloadContent',
                {'type': 'PDOC', 'key': text(selected['id'])},
              ).toString(),
            },
          },
        ],
      };
      headers = {};
    }
    await target.parent.create(recursive: true);
    final stage = await Directory(
      p.join(directory.path, profile.id, 'kindle-staging'),
    ).create(recursive: true);
    final temporary = await stage.createTemp('book-');
    final resources = <Json>[];
    var transferred = 0;
    try {
      final parts = (manifest['resources'] as List).map(object).toList();
      final identities = <String>{};
      for (var index = 0; index < parts.length; index++) {
        final part = parts[index], type = text(parts[index]['type']);
        final resourceId = text(part['id']);
        if (resourceId.isEmpty || !identities.add(resourceId)) {
          throw const KindleFailure('resource_shape');
        }
        final suffix = switch (type) {
          'KINDLE_MAIN_BASE' => '.azw',
          'KINDLE_MAIN_METADATA' => '.azw.md',
          'KINDLE_MAIN_ATTACHABLE' => '.azw.res',
          'KINDLE_USER_ANOT' => '.mbpV2',
          'DRM_VOUCHER' => '.voucher',
          _ => '.bin',
        };
        final file = File(
          p.join(
            temporary.path,
            '${index.toString().padLeft(4, '0')}-${sha256.convert(utf8.encode(resourceId)).toString().substring(0, 16)}$suffix',
          ),
        );
        final urls = <Uri>[];
        for (final (key, field) in [
          ('optimalEndpoint', 'directUrl'),
          ('endpoint', 'url'),
        ]) {
          final endpoint = object(part[key]);
          if (text(endpoint['httpMethod'], text(endpoint['method'], 'GET')) !=
              'GET') {
            throw const KindleFailure('resource_method');
          }
          final raw = text(endpoint[field]);
          if (raw.isEmpty) continue;
          final uri = Uri.tryParse(raw);
          if (uri == null || !kindleAllowedUri(uri)) {
            throw const KindleFailure('delivery_address');
          }
          if (!urls.contains(uri)) urls.add(uri);
        }
        if (urls.isEmpty) throw const KindleFailure('resource_endpoint');
        final optional =
            type == 'KINDLE_USER_ANOT' &&
            const {
              'DEFERRED',
              'PREFERRED',
            }.contains(text(part['requirement']).toUpperCase());
        // Notes are fetched separately through the sidecar service. Deferred
        // annotation packages are not required to render or map the book.
        if (optional) continue;
        KindleFailure? failure;
        var success = false;
        for (final url in urls) {
          check();
          try {
            final response = await client.request(
              url,
              headers: headers,
              abortTrigger: abortTrigger,
            );
            if (response.statusCode != 200 ||
                response.headers['content-encoding'] != null &&
                    response.headers['content-encoding'] != 'identity') {
              await response.stream.drain<void>();
              throw KindleFailure(
                'resource_response',
                status: response.statusCode,
              );
            }
            final expected = response.contentLength;
            if (expected != null &&
                (expected < 1 || expected > 2 * 1024 * 1024 * 1024)) {
              await response.stream.drain<void>();
              throw const KindleFailure('resource_size');
            }
            final sink = file.openWrite();
            var size = 0;
            try {
              await for (final bytes in response.stream.timeout(
                const Duration(seconds: 90),
              )) {
                check();
                size += bytes.length;
                transferred += bytes.length;
                if (size > 2 * 1024 * 1024 * 1024 ||
                    transferred > 4 * 1024 * 1024 * 1024) {
                  throw const KindleFailure('resource_size');
                }
                sink.add(bytes);
                progress?.call(transferred, null);
              }
            } finally {
              await sink.close();
            }
            if (size == 0 || expected != null && expected != size) {
              throw const KindleFailure('resource_truncated');
            }
            await _validateResource(
              file,
              type,
              response.headers['content-type'] ?? '',
            );
            final hash = await sha256.bind(file.openRead()).first;
            resources.add({
              'file': p.basename(file.path),
              'bytes': size,
              'sha256': hash.toString(),
              'type': type,
            });
            success = true;
            break;
          } on KindleFailure catch (error) {
            failure = error;
            if (await file.exists()) await file.delete();
            if (error.code == 'cancelled') rethrow;
            if (!const {401, 403, 404}.contains(error.status) &&
                !const {
                  'resource_service',
                  'resource_page',
                }.contains(error.code)) {
              break;
            }
          } catch (_) {
            failure = const KindleFailure('network');
            break;
          }
        }
        if (!success && !optional) {
          throw failure ?? const KindleFailure('resource_unavailable');
        }
      }
      check();
      if (!resources.any((part) => part['type'] == 'KINDLE_MAIN_BASE')) {
        throw const KindleFailure('resource_shape');
      }
      await File(p.join(temporary.path, 'receipt.json')).writeAsString(
        jsonEncode({
          'schema': 1,
          'download_state': 'complete',
          'book': selected,
          'resources': resources,
        }),
      );
      // Preparation is off the Flutter UI thread and receives files only.
      progress?.call(transferred, transferred);
      final prepared = await preparation.prepare(
        temporary,
        abortTrigger: abortTrigger,
      );
      check();
      final source = File(p.join(temporary.path, text(prepared['file'])));
      final format = text(prepared['format']);
      if (format == 'pdf') {
        updatePages(id, integer(prepared['pages']), estimated: false);
      }
      if (format == 'epub') {
        final path = source.path;
        final inspected = await compute(_inspectPreparedEpub, path);
        final cover = inspected['cover'] as Uint8List?;
        final weights = (inspected['weights'] as List).cast<int>();
        store.cache(profile.id, 'epubPageIndex:$id', {
          'schema': 1,
          'size': await source.length(),
          'hash': text(selected['revision']),
          'weights': weights,
        });
        final media = object(
          object(store.cached(profile.id, 'book:$id'))['media'],
        );
        if (integer(media['pagesCount']) == 0 ||
            media['pagesCountEstimated'] == true) {
          updatePages(id, EpubPageIndex(weights).pages);
        }
        if (cover != null) {
          final file = coverFile(id);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(cover, flush: true);
        }
      }
      check();
      final staged = File('${target.path}.kindle.part');
      await source.copy(staged.path);
      check();
      if (await target.exists()) await target.delete();
      await staged.rename(target.path);
      store.setSetting('kindleFormat:${profile.id}:$id', format);
      store.setSetting(
        'kindleMapped:${profile.id}:$id',
        prepared['kindle_locator_map'] == true,
      );
      store.cacheBooks(profile.id, [CatalogItem('books', bookJson(selected))]);
      onPrepared?.call(id);
      progress?.call(transferred, transferred);
      return target;
    } finally {
      if (await temporary.exists()) await temporary.delete(recursive: true);
      final staged = File('${target.path}.kindle.part');
      if (await staged.exists()) await staged.delete();
    }
  }
}

Future<void> _validateResource(File file, String type, String mime) async {
  final stream = file.openRead(0, (await file.length()).clamp(0, 4096));
  final prefix = await stream.fold<List<int>>(
    <int>[],
    (all, chunk) => all..addAll(chunk),
  );
  final textPrefix = utf8
      .decode(prefix, allowMalformed: true)
      .trimLeft()
      .toLowerCase();
  if (mime.toLowerCase().contains('text/html') ||
      textPrefix.startsWith('<html') ||
      textPrefix.startsWith('<!doctype html')) {
    throw const KindleFailure('resource_page');
  }
  if (textPrefix.startsWith('{') ||
      textPrefix.startsWith('[') ||
      textPrefix.startsWith('<')) {
    if (await file.length() > 16 * 1024 * 1024) {
      throw const KindleFailure('resource_size');
    }
    try {
      final data = await file.readAsString();
      if (textPrefix.startsWith('<')) {
        final xml = XmlDocument.parse(data);
        if (const {
              'error',
              'errorresponse',
              'errors',
            }.contains(xml.rootElement.name.local.toLowerCase()) ||
            xml.rootElement.childElements.any(
              (e) => e.name.local.toLowerCase() == 'error',
            )) {
          throw const KindleFailure('resource_service');
        }
      } else {
        final decoded = jsonDecode(data);
        if (decoded is Map &&
            decoded.keys.any(
              (key) => const {
                'error',
                'errors',
                'errorcode',
              }.contains('$key'.toLowerCase()),
            )) {
          throw const KindleFailure('resource_service');
        }
      }
    } on KindleFailure {
      rethrow;
    } catch (_) {
      throw const KindleFailure('resource_service');
    }
    if (type == 'KINDLE_MAIN_BASE') {
      throw const KindleFailure('resource_service');
    }
  }
}

Json _inspectPreparedEpub(String path) {
  EpubDocument book;
  try {
    book = EpubDocument.open(path);
  } catch (_) {
    throw const KindleFailure('invalid_epub');
  }
  try {
    return {'cover': _epubCover(book), 'weights': countEpubText(book)};
  } finally {
    book.close();
  }
}

Uint8List? _epubCover(EpubDocument book) {
  try {
    final container = XmlDocument.parse(
      EpubDocument.decodeText(book.resource('META-INF/container.xml')),
    );
    final package = container.descendants
        .whereType<XmlElement>()
        .firstWhere((e) => e.name.local == 'rootfile')
        .getAttribute('full-path')!;
    final opf = XmlDocument.parse(
      EpubDocument.decodeText(book.resource(package)),
    );
    final items = opf.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'item')
        .toList();
    final legacy = opf.descendants
        .whereType<XmlElement>()
        .where(
          (e) => e.name.local == 'meta' && e.getAttribute('name') == 'cover',
        )
        .firstOrNull
        ?.getAttribute('content');
    final cover = items
        .where(
          (e) =>
              (e.getAttribute('properties') ?? '')
                  .split(' ')
                  .contains('cover-image') ||
              e.getAttribute('id') == legacy,
        )
        .firstOrNull;
    if (cover == null) return null;
    final bytes = book.resource(
      EpubDocument.resolve(package, cover.getAttribute('href')!),
    );
    return bytes.length <= 16 * 1024 * 1024 ? bytes : null;
  } catch (_) {
    return null;
  }
}
