import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Crop thresholds and safety limits follow ReaderPageBorderCropper upstream.
/// Only a small analysis image is decoded; the original remains unchanged.
class PageCrop {
  const PageCrop(this.bounds, this.aspect);
  final Rect bounds;
  final double aspect;
}

final _analysis = Expando<Map<String, Future<PageCrop?>>>();

Future<PageCrop?> pageCrop(Uint8List bytes, String mode) {
  if (mode == 'disabled') return SynchronousFuture(null);
  final modes = _analysis[bytes] ??= {};
  return modes.putIfAbsent(mode, () => _analyze(bytes, mode));
}

Future<PageCrop?> _analyze(Uint8List bytes, String mode) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width, height = descriptor.height;
    if (width < 64 || height < 64) return null;
    // Bound analysis cost for very large scans without retaining raster copies.
    final scale = math.min(.4, 1024 / math.max(width, height));
    final w = math.max(1, (width * scale).round());
    final h = math.max(1, (height * scale).round());
    codec = await descriptor.instantiateCodec(targetWidth: w, targetHeight: h);
    image = (await codec.getNextFrame()).image;
    final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (pixels == null) return null;
    final bounds = await compute(cropBounds, (
      pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes),
      w,
      h,
      mode,
    ));
    if (bounds == null) return null;
    return PageCrop(bounds, width * bounds.width / (height * bounds.height));
  } catch (_) {
    // A failure of optional processing must not make a readable page disappear.
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Returns normalized content bounds, or null when cropping would be unsafe.
@visibleForTesting
Rect? cropBounds((Uint8List, int, int, String) input) {
  final (pixels, width, height, mode) = input;
  if (mode == 'disabled' || pixels.length != width * height * 4) return null;
  final aggressive = mode == 'aggressive';
  final white = aggressive ? 170 : 238, black = aggressive ? 32 : 5;
  var left = width, top = height, right = -1, bottom = -1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      final r = pixels[i], g = pixels[i + 1], b = pixels[i + 2];
      if (pixels[i + 3] == 0 ||
          r >= white && g >= white && b >= white ||
          r <= black && g <= black && b <= black) {
        continue;
      }
      left = math.min(left, x);
      right = math.max(right, x);
      top = math.min(top, y);
      bottom = math.max(bottom, y);
    }
  }
  if (right < left || bottom < top) return null;
  final px = aggressive ? 0 : (width * .018).round();
  final py = aggressive ? 0 : (height * .018).round();
  left = math.max(0, left - px);
  right = math.min(width - 1, right + px);
  top = math.max(0, top - py);
  bottom = math.min(height - 1, bottom + py);
  final bounds = Rect.fromLTRB(
    left / width,
    top / height,
    (right + 1) / width,
    (bottom + 1) / height,
  );
  final retained = aggressive ? .35 : .75;
  final limit = aggressive ? .6 : .2;
  if (bounds.width < retained ||
      bounds.height < retained ||
      [
        bounds.left,
        bounds.top,
        1 - bounds.right,
        1 - bounds.bottom,
      ].any((v) => v > limit) ||
      bounds == const Rect.fromLTWH(0, 0, 1, 1)) {
    return null;
  }
  return bounds;
}

/// Fits the cropped rectangle, then clips the full original image underneath.
/// No large encoded PNG copy or additional full-resolution decode is needed.
class PageCropView extends StatelessWidget {
  const PageCropView({
    super.key,
    required this.crop,
    required this.fit,
    required this.child,
  });
  final PageCrop crop;
  final BoxFit fit;
  final Widget child;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final target = Size(
        constraints.maxWidth,
        constraints.hasBoundedHeight
            ? constraints.maxHeight
            : constraints.maxWidth / crop.aspect,
      );
      final fitted = applyBoxFit(fit, Size(crop.aspect, 1), target);
      // cover/fitWidth can extend beyond the viewport; the outer clip handles it.
      final scale = fit == BoxFit.cover
          ? math.max(target.width / crop.aspect, target.height)
          : fit == BoxFit.fitWidth
          ? target.width / crop.aspect
          : fitted.destination.height;
      final width = crop.aspect * scale, height = scale;
      return SizedBox(
        width: target.width,
        height: target.height,
        child: ClipRect(
          child: Center(
            child: OverflowBox(
              minWidth: width,
              maxWidth: width,
              minHeight: height,
              maxHeight: height,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment(
                    crop.bounds.width == 1
                        ? 0
                        : 2 * crop.bounds.left / (1 - crop.bounds.width) - 1,
                    crop.bounds.height == 1
                        ? 0
                        : 2 * crop.bounds.top / (1 - crop.bounds.height) - 1,
                  ),
                  minWidth: width / crop.bounds.width,
                  maxWidth: width / crop.bounds.width,
                  minHeight: height / crop.bounds.height,
                  maxHeight: height / crop.bounds.height,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
