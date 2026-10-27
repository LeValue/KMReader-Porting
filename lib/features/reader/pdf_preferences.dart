import 'dart:math' as math;
import 'dart:ui';

import '../../core/models.dart';

enum PdfPresentation {
  auto('auto', 'Auto'),
  singlePaged('single-paged', 'Single Page'),
  singleContinuous('single-continuous', 'Single Page Continuous'),
  dualContinuous('dual-continuous', 'Dual Page Continuous');

  const PdfPresentation(this.value, this.label);
  final String value, label;
  PdfPresentation resolved(Size viewport) => this == auto
      ? viewport.width > viewport.height
            ? dualContinuous
            : singlePaged
      : this;
}

class PdfPreferences {
  const PdfPreferences({
    this.presentation = PdfPresentation.auto,
    this.rtl = false,
    this.coverSolo = true,
    this.background = 'white',
    this.useSeriesDirection = true,
  });
  final PdfPresentation presentation;
  final bool rtl, coverSolo, useSeriesDirection;
  final String background;
  factory PdfPreferences.fromJson(Json json) => PdfPreferences(
    presentation: PdfPresentation.values.firstWhere(
      (value) => value.value == json['presentation'],
      orElse: () => PdfPresentation.auto,
    ),
    rtl: json['rtl'] == true,
    coverSolo: json['coverSolo'] != false,
    background: const ['white', 'sepia', 'black'].contains(json['background'])
        ? json['background'] as String
        : 'white',
    useSeriesDirection: json['useSeriesDirection'] != false,
  );
  Json toJson() => {
    'presentation': presentation.value,
    'rtl': rtl,
    'coverSolo': coverSolo,
    'background': background,
    'useSeriesDirection': useSeriesDirection,
  };
  PdfPreferences copy({
    PdfPresentation? presentation,
    bool? rtl,
    bool? coverSolo,
    String? background,
    bool? useSeriesDirection,
  }) => PdfPreferences(
    presentation: presentation ?? this.presentation,
    rtl: rtl ?? this.rtl,
    coverSolo: coverSolo ?? this.coverSolo,
    background: background ?? this.background,
    useSeriesDirection: useSeriesDirection ?? this.useSeriesDirection,
  );
  PdfPreferences forSeries(Json metadata) {
    if (!useSeriesDirection) return this;
    return switch (metadata['readingDirection']) {
      'RIGHT_TO_LEFT' => copy(rtl: true),
      'LEFT_TO_RIGHT' => copy(rtl: false),
      'VERTICAL' || 'WEBTOON' => copy(
        rtl: false,
        presentation: PdfPresentation.singleContinuous,
      ),
      _ => this,
    };
  }
}

/// Coordinates remain indexed in canonical PDF order, even for RTL spreads.
class PdfReaderLayout {
  PdfReaderLayout._(this.pages, this.slots, this.documentSize);
  final List<Rect> pages, slots;
  final Size documentSize;
  factory PdfReaderLayout({
    required List<Size> sizes,
    required PdfPreferences preferences,
    required Size viewport,
    double margin = 8,
  }) {
    if (sizes.isEmpty) return PdfReaderLayout._([], [], Size.zero);
    final mode = preferences.presentation.resolved(viewport);
    final maxWidth = sizes.fold(0.0, (w, p) => math.max(w, p.width));
    final maxHeight = sizes.fold(0.0, (h, p) => math.max(h, p.height));
    final pages = List<Rect>.filled(sizes.length, Rect.zero);
    final slots = List<Rect>.filled(sizes.length, Rect.zero);
    if (mode == PdfPresentation.singlePaged) {
      final ratio = viewport.width > 0 && viewport.height > 0
          ? viewport.width / viewport.height
          : 1.0;
      final width = math.max(
        maxWidth + 2 * margin,
        (maxHeight + 2 * margin) * ratio,
      );
      final height = width / ratio;
      for (var i = 0; i < sizes.length; i++) {
        final x = (preferences.rtl ? sizes.length - i - 1 : i) * width;
        pages[i] = Rect.fromLTWH(
          x + (width - sizes[i].width) / 2,
          (height - sizes[i].height) / 2,
          sizes[i].width,
          sizes[i].height,
        );
        slots[i] = Rect.fromLTWH(x, 0, width, height);
      }
      return PdfReaderLayout._(
        pages,
        slots,
        Size(width * sizes.length, height),
      );
    }
    final dual = mode == PdfPresentation.dualContinuous;
    final width = (dual ? 2 : 1) * maxWidth + (dual ? 3 : 2) * margin;
    var y = margin;
    for (var i = 0; i < sizes.length;) {
      final paired =
          dual && !(preferences.coverSolo && i == 0) && i + 1 < sizes.length;
      final last = paired ? i + 1 : i;
      final rowHeight = paired
          ? math.max(sizes[i].height, sizes[last].height)
          : sizes[i].height;
      final rowWidth =
          sizes[i].width + (paired ? margin + sizes[last].width : 0);
      var x = (width - rowWidth) / 2;
      final order = paired && preferences.rtl
          ? [last, i]
          : [i, if (paired) last];
      for (final index in order) {
        pages[index] = Rect.fromLTWH(
          x,
          y + (rowHeight - sizes[index].height) / 2,
          sizes[index].width,
          sizes[index].height,
        );
        slots[index] = Rect.fromLTWH(
          0,
          y - margin / 2,
          width,
          rowHeight + margin,
        );
        x += sizes[index].width + margin;
      }
      y += rowHeight + margin;
      i = last + 1;
    }
    return PdfReaderLayout._(pages, slots, Size(width, y));
  }
  int nearestPage(Rect viewport, {int? preferred}) {
    if (pages.isEmpty) return 1;
    var page = 1, distance = double.infinity;
    for (var i = 0; i < slots.length; i++) {
      final next = (slots[i].center - viewport.center).distanceSquared;
      if (next < distance) {
        distance = next;
        page = i + 1;
      }
    }
    if (preferred != null &&
        preferred > 0 &&
        preferred <= pages.length &&
        pages[preferred - 1].overlaps(viewport)) {
      return preferred;
    }
    // When zooming into the other page of a spread, the row still has the same
    // slot. Choose its visible page rather than a hidden canonical first page.
    if (!pages[page - 1].overlaps(viewport)) {
      for (var i = 0; i < pages.length; i++) {
        if (slots[i] == slots[page - 1] && pages[i].overlaps(viewport)) {
          return i + 1;
        }
      }
    }
    return page;
  }
}
