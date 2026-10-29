import 'api.dart';
import 'models.dart';
import 'repository.dart';

class NextBookResolver {
  const NextBookResolver(this.repository);
  final Repository repository;
  bool get skipRead =>
      repository.store.setting<bool>('suggestNextUnreadBook') != false;

  List<Book> _siblings(Book current, String? readListId) {
    if (readListId == null && current.seriesId.isEmpty) return [];
    final chunk = repository.store.offlineCatalog.query(
      repository.profile.id,
      'books',
      path: readListId == null
          ? '/api/v1/series/${Uri.encodeComponent(current.seriesId)}/books'
          : '/api/v1/readlists/${Uri.encodeComponent(readListId)}/books',
      sort: 'metadata.numberSort,asc',
      size: 1000,
    );
    return chunk.items.map((item) => repository.overlay(item.book)).toList();
  }

  Book? locallyAfter(
    Book current, {
    String? readListId,
    String? excludeReadId,
  }) {
    final siblings = _siblings(current, readListId);
    final index = siblings.indexWhere((book) => book.id == current.id);
    if (index < 0) return null;
    final later = siblings.skip(index + 1).toList();
    if (!skipRead) return later.firstOrNull;
    return later
            .where((book) => book.id != excludeReadId && !book.completed)
            .firstOrNull ??
        (excludeReadId == null ? later.firstOrNull : null);
  }

  Future<Book?> after(Book current, {String? readListId}) async {
    if (repository.offline) {
      return locallyAfter(current, readListId: readListId);
    }
    final prefix = readListId == null
        ? '/api/v1/books/${Uri.encodeComponent(current.id)}'
        : '/api/v1/readlists/${Uri.encodeComponent(readListId)}/books/${Uri.encodeComponent(current.id)}';
    try {
      final raw = await repository.get(
        '$prefix/next',
        query: {if (skipRead) 'skipRead': 'true'},
      );
      if (raw == null || object(raw).isEmpty) return null;
      final book = Book(object(raw));
      if (skipRead && book.completed) {
        return locallyAfter(
              current,
              readListId: readListId,
              excludeReadId: book.id,
            ) ??
            repository.overlay(book);
      }
      return repository.overlay(book);
    } on ApiFailure catch (error) {
      if (error.status == 404) return null;
      rethrow;
    }
  }
}
