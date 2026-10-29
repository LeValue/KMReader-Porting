import '../../core/models.dart';

/// Prevents an accidental open from changing an unread or completed book.
class ReaderProgressGate {
  ReaderProgressGate(this.book, this.threshold)
    : start = book.completed
          ? 1
          : book.page.clamp(1, book.pages > 0 ? book.pages : 1);
  final Book book;
  final int threshold, start;
  bool recorded = false;
  bool allows(int page, {int? distance, bool? completed}) {
    final finished = completed ?? (book.pages > 0 && page >= book.pages);
    final required =
        (book.page > 0 && !book.completed ? threshold.clamp(0, 1) : threshold)
            .clamp(0, book.pages > 0 ? book.pages - 1 : threshold);
    if (!finished &&
        !recorded &&
        (distance ?? (page - start).abs()) < required) {
      return false;
    }
    recorded = true;
    return true;
  }
}
