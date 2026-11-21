import 'dart:math' as math;
import 'dart:ui';

import '../../core/models.dart';

enum PdfPresentation {
  auto('auto', 'Auto'),
  singlePaged('single-paged', 'Single Page'),
  dualPaged('dual-paged', 'Dual Page'),
  singleContinuous('single-continuous', 'Single Page Continuous'),
  dualContinuous('dual-continuous', 'Dual Page Continuous');

  const PdfPresentation(this.value, this.label);
  final String value, label;
  bool get isPaged => this == singlePaged || this == dualPaged;
  bool get isDual => this == dualPaged || this == dualContinuous;
  PdfPresentation resolved(Size viewport) => this == auto
      ? viewport.width > viewport.height
            ? dualPaged
            : singlePaged
      : this;
}

class PdfPreferences {
  const PdfPreferences({
    this.presentation = PdfPresentation.auto,
    this.rtl = false,
    this.vertical = false,
    this.coverSolo = true,
    this.background = 'white',
    this.useSeriesDirection = true,
    this.controlsGradient = true,
    this.showProgress = false,
  });
  final PdfPresentation presentation;
  final bool rtl,
      vertical,
      coverSolo,
      useSeriesDirection,
      controlsGradient,
      showProgress;
  final String background;
  factory PdfPreferences.fromJson(Json json) => PdfPreferences(
    presentation: PdfPresentation.values.firstWhere(
      (value) => value.value == json['presentation'],
      orElse: () => PdfPresentation.auto,
    ),
    rtl: json['rtl'] == true,
    vertical: json['vertical'] == true,
    coverSolo: json['coverSolo'] != false,
    background:
        const [
          'white',
          'sepia',
          'black',
          'gray',
          'system',
        ].contains(json['background'])
        ? json['background'] as String
        : 'white',
    useSeriesDirection: json['useSeriesDirection'] != false,
    controlsGradient: json['controlsGradient'] != false,
    showProgress: json['showProgress'] == true,
  );
  Json toJson() => {
    'presentation': presentation.value,
    'rtl': rtl,
    'vertical': vertical,
    'coverSolo': coverSolo,
    'background': background,
    'useSeriesDirection': useSeriesDirection,
    'controlsGradient': controlsGradient,
    'showProgress': showProgress,
  };
  PdfPreferences copy({
    PdfPresentation? presentation,
    bool? rtl,
    bool? vertical,
    bool? coverSolo,
    String? background,
    bool? useSeriesDirection,
    bool? controlsGradient,
    bool? showProgress,
  }) => PdfPreferences(
    presentation: presentation ?? this.presentation,
    rtl: rtl ?? this.rtl,
    vertical: vertical ?? this.vertical,
    coverSolo: coverSolo ?? this.coverSolo,
    background: background ?? this.background,
    useSeriesDirection: useSeriesDirection ?? this.useSeriesDirection,
    controlsGradient: controlsGradient ?? this.controlsGradient,
    showProgress: showProgress ?? this.showProgress,
  );
  PdfPreferences forSeries(Json metadata) {
    if (!useSeriesDirection) return this;
    return switch (metadata['readingDirection']) {
      'RIGHT_TO_LEFT' => copy(rtl: true, vertical: false),
      'LEFT_TO_RIGHT' => copy(rtl: false, vertical: false),
      'VERTICAL' || 'WEBTOON' => copy(rtl: false, vertical: true),
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
    if (mode.isPaged) {
      final ratio = viewport.width > 0 && viewport.height > 0
          ? viewport.width / viewport.height
          : 1.0;
      final width = math.max(
        maxWidth * (mode.isDual ? 2 : 1) + (mode.isDual ? 3 : 2) * margin,
        (maxHeight + 2 * margin) * ratio,
      );
      final height = width / ratio;
      final solo = mode.isDual && preferences.coverSolo;
      final count = mode.isDual
          ? (sizes.length + (solo ? 2 : 1)) ~/ 2
          : sizes.length;
      for (var i = 0, spread = 0; i < sizes.length; spread++) {
        final paired = mode.isDual && !(solo && i == 0) && i + 1 < sizes.length;
        final last = paired ? i + 1 : i;
        final x = preferences.vertical
            ? 0.0
            : (preferences.rtl ? count - spread - 1 : spread) * width;
        final y = preferences.vertical ? spread * height : 0.0;
        final rowWidth =
            sizes[i].width + (paired ? margin + sizes[last].width : 0);
        var left = x + (width - rowWidth) / 2;
        for (final index
            in paired && preferences.rtl ? [last, i] : [i, if (paired) last]) {
          pages[index] = Rect.fromLTWH(
            left,
            y + (height - sizes[index].height) / 2,
            sizes[index].width,
            sizes[index].height,
          );
          slots[index] = Rect.fromLTWH(x, y, width, height);
          left += sizes[index].width + margin;
        }
        i = last + 1;
      }
      return PdfReaderLayout._(
        pages,
        slots,
        preferences.vertical
            ? Size(width, height * count)
            : Size(width * count, height),
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

  int? adjacentPage(int page, int direction) {
    if (page < 1 || page > slots.length || direction.abs() != 1) return null;
    final current = slots[page - 1];
    var index = page - 1 + direction;
    while (index >= 0 && index < slots.length && slots[index] == current) {
      index += direction;
    }
    if (index < 0 || index >= slots.length) return null;
    while (index > 0 && slots[index - 1] == slots[index]) {
      index--;
    }
    return index + 1;
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
