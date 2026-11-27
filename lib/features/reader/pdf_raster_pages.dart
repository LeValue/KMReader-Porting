import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import '../../core/cache.dart';
import '../../core/models.dart';
import 'raster_pages.dart';

enum PdfRasterQuality {
  compact(2048, 'Compact (2048 px)'),
  balanced(3072, 'Balanced (3072 px)'),
  high(4096, 'High (4096 px)'),
  ultra(5120, 'Ultra (5120 px)');

  const PdfRasterQuality(this.maxLongEdge, this.label);
  final int maxLongEdge;
  final String label;
  static PdfRasterQuality parse(String? value) => values.firstWhere(
    (quality) => quality.name == value,
    orElse: () => balanced,
  );
}

/// Serial native PDFium rendering. Encoded derivatives stay in bounded memory;
/// the downloaded original is sufficient for offline and incognito reading.
class PdfRasterPages implements RasterPages {
  PdfRasterPages(this.document, {this.quality = PdfRasterQuality.balanced});
  final PdfDocument document;
  final PdfRasterQuality quality;
  final _cache = WeightedCache<int, Uint8List>(
    maxWeight: 32 * 1024 * 1024,
    maxEntries: 16,
    weight: (bytes) => bytes.length,
  );
  final _pending = <int, Future<Uint8List>>{};
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  bool _closed = false;
  bool get isRendering => _pending.isNotEmpty;
  @override
  List<Json> get dimensions => [
    for (final page in document.pages)
      {
        'number': page.pageNumber,
        'width': page.width.round(),
        'height': page.height.round(),
      },
  ];

  @override
  Future<Uint8List> page(int number, {bool refresh = false}) {
    if (_closed) return Future.error(StateError('PDF reader closed.'));
    if (number < 1 || number > document.pages.length) {
      return Future.error(RangeError.range(number, 1, document.pages.length));
    }
    final existing = _pending[number];
    if (existing != null) return existing;
    if (refresh) _cache.remove(number);
    final cached = _cache[number];
    if (cached != null) return Future.value(cached);
    final result = _withDocument(() => _render(number));
    _pending[number] = result;
    return result.whenComplete(() => _pending.remove(number));
  }

  Future<T> _withDocument<T>(Future<T> Function() read) {
    final result = _tail.then((_) {
      if (_closed) throw StateError('PDF reader closed.');
      return read();
    });
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<List<PdfOutlineNode>> outline() => _withDocument(document.loadOutline);

  Future<String> textForPage(int number) => _withDocument(() async {
    final text = await document.pages[number - 1].loadText();
    return text?.fullText ?? '';
  });

  Future<Uint8List> _render(int number) async {
    if (_closed) throw StateError('PDF reader closed.');
    final bytes = await renderPage(
      document.pages[number - 1],
      quality: quality,
    );
    if (!_closed) _cache.put(number, bytes);
    return bytes;
  }

  static Future<Uint8List> renderPage(
    PdfPage page, {
    required PdfRasterQuality quality,
  }) async {
    if (!page.width.isFinite ||
        !page.height.isFinite ||
        page.width <= 0 ||
        page.height <= 0) {
      throw const FormatException('Invalid PDF page size.');
    }
    // Quality specifies a maximum edge; cap raw raster allocation at 64 MiB.
    final scale = math.min(
      quality.maxLongEdge / math.max(page.width, page.height),
      math.sqrt(16 * 1024 * 1024 / (page.width * page.height)),
    );
    final width = (page.width * scale).floor().clamp(1, quality.maxLongEdge);
    final height = (page.height * scale).floor().clamp(1, quality.maxLongEdge);
    final rendered = await page.render(
      fullWidth: width.toDouble(),
      fullHeight: height.toDouble(),
      backgroundColor: 0xffffffff,
    );
    if (rendered == null) throw StateError('PDF page rendering failed.');
    try {
      final image = await rendered.createImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('PDF page rendering failed.');
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        image.dispose();
      }
    } finally {
      rendered.dispose();
    }
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= _stop();
  }

  Future<void> _stop() async {
    await _tail;
    _cache.clear();
    await document.dispose();
  }
}
