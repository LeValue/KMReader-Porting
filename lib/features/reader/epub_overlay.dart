import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../ui/strings.dart';
import 'epub_session.dart';

String epubOverlayText(BuildContext context, EpubSession session, String slot) {
  final values = object(
    session.repository.store.setting<dynamic>('epubOverlay'),
  );
  const defaults = {
    'readerHeaderCenter': 'bookTitle',
    'readerFooterLeading': 'chapterTitle',
    'readerFooterTrailing': 'chapterRemaining',
    'controlsHeaderCenter': 'bookProgressPercent',
    'controlsFooterCenter': 'chapterPosition',
  };
  final item = text(values[slot], defaults[slot] ?? 'none');
  final bookProgress =
      (session.chapter + session.progression) /
      session.document.chapters.length;
  return switch (item) {
    'bookTitle' => session.book.title,
    'chapterTitle' => session.document.chapters[session.chapter].title,
    'bookProgressPercent' => '${(bookProgress * 100).round()}%',
    'bookRemainingPercent' => '${((1 - bookProgress) * 100).round()}%',
    'chapterProgressPercent' => '${(session.progression * 100).round()}%',
    'chapterRemaining' =>
      '${(session.pages - session.page).clamp(0, session.pages)} ${tr(context, 'Pages')}',
    'chapterPosition' => '${session.page}/${session.pages}',
    _ => '',
  };
}

class EpubReadingOverlay extends StatelessWidget {
  const EpubReadingOverlay({
    super.key,
    required this.session,
    required this.header,
  });
  final EpubSession session;
  final bool header;
  @override
  Widget build(BuildContext context) {
    final slots = header
        ? ['readerHeaderLeading', 'readerHeaderCenter', 'readerHeaderTrailing']
        : ['readerFooterLeading', 'readerFooterCenter', 'readerFooterTrailing'];
    final labels = slots
        .map((slot) => epubOverlayText(context, session, slot))
        .toList();
    if (labels.every((label) => label.isEmpty)) return const SizedBox.shrink();
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            for (var i = 0; i < 3; i++)
              Expanded(
                child: Text(
                  labels[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: i == 0
                      ? TextAlign.start
                      : i == 1
                      ? TextAlign.center
                      : TextAlign.end,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
