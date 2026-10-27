import '../../core/models.dart';

class PagePart {
  const PagePart(this.page, [this.half = 0, this.aspect = 1]);
  final int page;
  final double aspect;

  /// 0 is full, 1 is the left half, 2 is the right half.
  final int half;
}

List<PagePart> pageParts(
  int count,
  List<Json> dimensions,
  ReaderPreferences settings,
) {
  final sizes = {for (final page in dimensions) integer(page['number']): page};
  final rtl =
      settings.splitWide == 'rtl' ||
      settings.splitWide == 'auto' &&
          settings.direction == ReadingDirection.rtl;
  return [
    for (var page = 1; page <= count; page++)
      if (settings.mode == ReadingMode.paged &&
          ['auto', 'ltr', 'rtl'].contains(settings.splitWide) &&
          integer(sizes[page]?['width']) > integer(sizes[page]?['height']) &&
          integer(sizes[page]?['height']) > 0) ...[
        PagePart(
          page,
          rtl ? 2 : 1,
          integer(sizes[page]?['width']) / integer(sizes[page]?['height']) / 2,
        ),
        PagePart(
          page,
          rtl ? 1 : 2,
          integer(sizes[page]?['width']) / integer(sizes[page]?['height']) / 2,
        ),
      ] else
        PagePart(page),
  ];
}
