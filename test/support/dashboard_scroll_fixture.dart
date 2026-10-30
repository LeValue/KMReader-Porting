import 'dart:async';

import 'package:flutter/services.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';

class DeferredDashboardRepository extends Repository {
  DeferredDashboardRepository({
    required super.profile,
    required super.store,
    required super.directory,
    required super.api,
    required this.imageBytes,
  });
  final Uint8List imageBytes;
  @override
  Future<Uint8List> image(String path, {bool refresh = false}) async =>
      imageBytes;
  final pending = <(Completer<CatalogPage>, CatalogPage)>[];
  int calls = 0;
  @override
  Future<CatalogPage> catalog(
    String kind, {
    int page = 0,
    String? search,
    String sort = 'metadata.titleSort,asc',
    Json? condition,
    String? path,
    bool force = false,
    int size = 40,
    String? libraryId,
    List<String>? libraryIds,
  }) {
    calls++;
    final empty = path?.endsWith('/ondeck') == true || condition != null;
    final result = CatalogPage(
      [
        if (!empty)
          for (var i = 0; i < 6; i++)
            CatalogItem(kind, {
              'id': '$kind:$sort:$i',
              'name': 'Item $i',
              'seriesId': 's',
              'metadata': {'title': 'Item $i'},
              'media': {'pagesCount': 20},
              'booksCount': 6,
            }),
      ],
      true,
      empty ? 0 : 6,
    );
    final completer = Completer<CatalogPage>();
    pending.add((completer, result));
    return completer.future;
  }

  void resolve() {
    final batch = [...pending];
    pending.clear();
    for (final (future, result) in batch) {
      future.complete(result);
    }
  }
}
