import 'dart:math' as math;

import 'package:html/parser.dart' as html;

import 'epub_document.dart';

/// Stable, book-wide logical pages. Calculated in a worker, never by asking
/// the WebView to lay out every chapter. One logical page is 1024 scalars.
class EpubPageIndex {
  EpubPageIndex(this.weights);
  final List<int> weights;
  int get length => weights.fold(0, (sum, value) => sum + value);
  int get pages => math.max(1, (length / 1024).ceil());
  double fraction(int chapter, double progression) {
    if (weights.isEmpty) return 0;
    final index = chapter.clamp(0, weights.length - 1);
    return ((weights.take(index).fold(0, (a, b) => a + b) +
                weights[index] * progression.clamp(0, 1)) /
            math.max(1, length))
        .clamp(0, 1);
  }

  int page(int chapter, double progression) =>
      math.min(pages, (fraction(chapter, progression) * pages).floor() + 1);
  (int, double) target(double fraction) {
    var remaining = fraction.clamp(0, 1) * length;
    for (var i = 0; i < weights.length; i++) {
      if (remaining < weights[i] || i == weights.length - 1) {
        return (i, (remaining / weights[i]).clamp(0, .999999));
      }
      remaining -= weights[i];
    }
    return (0, 0);
  }
}

List<int> countEpubText(EpubDocument document) => [
  for (var index = 0; index < document.chapters.length; index++)
    _count(document.chapter(index)),
];
int _count(String source) {
  final document = html.parse(source);
  for (final node in document.querySelectorAll('script,style,noscript')) {
    node.remove();
  }
  return math.max(1, (document.body?.text ?? '').runes.length);
}

List<int> indexEpubFile(String path) {
  final document = EpubDocument.open(path);
  try {
    return countEpubText(document);
  } finally {
    document.close();
  }
}
