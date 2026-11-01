import 'comic_spread.dart';

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Already composed pages avoid a GPU readback at the start of a gesture.
/// The cache owns originals; transitions borrow clones until their last frame.
class ComicFrame {
  ComicFrame(this.image, this.leaves);
  final ui.Image image;
  final List<Rect> leaves;
  ComicFrame clone() => ComicFrame(image.clone(), leaves);
}

class ComicFrames {
  final _frames = <String, ComicFrame>{};
  final _pending = <String, Future<void>>{};
  bool _closed = false;
  ComicFrame? borrow(String key) {
    final frame = _frames.remove(key);
    if (frame == null) return null;
    _frames[key] = frame;
    return frame.clone();
  }

  Future<void> warm({
    required String key,
    required Size size,
    required int first,
    required int count,
    required int pageCount,
    required bool rtl,
    required Color background,
    required Future<Uint8List> Function(int) load,
  }) {
    if (_closed || _frames.containsKey(key)) return Future.value();
    return _pending
        .putIfAbsent(key, () async {
          final ratio = math.min(2.0, 2048 / size.longestSide);
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)..scale(ratio);
          canvas.drawRect(Offset.zero & size, Paint()..color = background);
          final leaves = <Rect>[];
          final decoded = <ui.Image>[];
          try {
            for (var physical = 0; physical < count; physical++) {
              final page = first + (rtl ? count - 1 - physical : physical);
              if (page > pageCount) {
                continue;
              }
              final bytes = await load(page);
              if (_closed) return;
              final codec = await ui.instantiateImageCodec(
                bytes,
                targetWidth: (size.width / count * ratio).ceil(),
              );
              late ui.Image image;
              try {
                image = (await codec.getNextFrame()).image;
              } finally {
                codec.dispose();
              }
              decoded.add(image);
            }
            final aspects = <double>[];
            var decodedIndex = 0;
            for (var physical = 0; physical < count; physical++) {
              final page = first + (rtl ? count - 1 - physical : physical);
              if (page > pageCount) {
                aspects.add(
                  decoded.isNotEmpty
                      ? decoded.first.width / decoded.first.height
                      : 1,
                );
              } else {
                final image = decoded[decodedIndex++];
                aspects.add(image.width / image.height);
              }
            }
            leaves.clear();
            leaves.addAll(comicLeafBounds(size, aspects));
            decodedIndex = 0;
            for (var physical = 0; physical < count; physical++) {
              final page = first + (rtl ? count - 1 - physical : physical);
              if (page > pageCount) continue;
              final image = decoded[decodedIndex++];
              canvas.drawImageRect(
                image,
                Rect.fromLTWH(
                  0,
                  0,
                  image.width.toDouble(),
                  image.height.toDouble(),
                ),
                leaves[physical],
                Paint()..filterQuality = FilterQuality.medium,
              );
            }
            final picture = recorder.endRecording();
            late ui.Image image;
            try {
              image = await picture.toImage(
                (size.width * ratio).ceil(),
                (size.height * ratio).ceil(),
              );
            } finally {
              picture.dispose();
            }
            if (_closed) {
              image.dispose();
              return;
            }
            _frames[key] = ComicFrame(image, leaves);
            var bytes = _frames.values.fold<int>(
              0,
              (total, frame) =>
                  total + frame.image.width * frame.image.height * 4,
            );
            while (_frames.length > 4 ||
                bytes > 48 * 1024 * 1024 && _frames.length > 1) {
              final oldest = _frames.remove(_frames.keys.first)!;
              bytes -= oldest.image.width * oldest.image.height * 4;
              oldest.image.dispose();
            }
          } finally {
            if (recorder.isRecording) recorder.endRecording().dispose();
            for (final image in decoded) {
              image.dispose();
            }
          }
        })
        .whenComplete(() => _pending.remove(key));
  }

  void close() {
    _closed = true;
    for (final frame in _frames.values) {
      frame.image.dispose();
    }
    _frames.clear();
  }
}
