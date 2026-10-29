import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import 'reader_ocr.dart';

class BubbleBox {
  const BubbleBox(this.bounds, this.confidence);
  final ui.Rect bounds;
  final double confidence;
}

class BubbleDetections {
  BubbleDetections(List<BubbleBox> boxes, this.maxScore)
    : boxes = List.unmodifiable(boxes);
  final List<BubbleBox> boxes;
  final double maxScore;
}

/// The upstream YOLO11n whole-bubble detector, with its 0.3/0.7 thresholds.
BubbleDetections decodeBubbleBoxes(Float32List values, {int columns = 8400}) {
  if (columns < 1 || columns > 20000 || values.length != columns * 5) {
    throw const FormatException('Invalid bubble detection output.');
  }
  final candidates =
      <({ui.Rect source, ui.Rect bounds, double score, int index})>[];
  var maximum = 0.0;
  for (var index = 0; index < columns; index++) {
    final score = values[4 * columns + index];
    if (!score.isFinite || score < 0 || score > 1) continue;
    maximum = math.max(maximum, score);
    if (score < .3) continue;
    final cx = values[index],
        cy = values[columns + index],
        width = values[2 * columns + index],
        height = values[3 * columns + index];
    if (![cx, cy, width, height].every((n) => n.isFinite) ||
        width <= 0 ||
        height <= 0) {
      continue;
    }
    final source = ui.Rect.fromLTWH(
      (cx - width / 2) / 640,
      (cy - height / 2) / 640,
      width / 640,
      height / 640,
    );
    final bounds = source.intersect(const ui.Rect.fromLTWH(0, 0, 1, 1));
    if (bounds.isEmpty) continue;
    candidates.add((
      source: source,
      bounds: bounds,
      score: score,
      index: index,
    ));
  }
  candidates.sort((a, b) {
    final score = b.score.compareTo(a.score);
    return score == 0 ? a.index.compareTo(b.index) : score;
  });
  final kept = <({ui.Rect source, ui.Rect bounds, double score, int index})>[];
  for (final candidate in candidates.take(2048)) {
    if (kept.any((other) => _iou(other.source, candidate.source) >= .7)) {
      continue;
    }
    kept.add(candidate);
    if (kept.length >= 256) break;
  }
  return BubbleDetections([
    for (final box in kept) BubbleBox(box.bounds, box.score),
  ], maximum);
}

double _iou(ui.Rect a, ui.Rect b) {
  final intersection = a.intersect(b);
  if (intersection.isEmpty) return 0;
  final area = intersection.width * intersection.height;
  return area / (a.width * a.height + b.width * b.height - area);
}

/// Merge lines belonging to a bubble while retaining captions and native order.
OcrDocument groupOcrBubbles(OcrDocument document, List<BubbleBox> bubbles) {
  if (bubbles.isEmpty || document.blocks.isEmpty) return document;
  final grouped = <int, List<OcrBlock>>{},
      order = <({int? bubble, OcrBlock block})>[];
  for (final block in document.blocks) {
    int? owner;
    var best = 0.0;
    for (var index = 0; index < bubbles.length; index++) {
      final bounds = bubbles[index].bounds;
      final overlap = bounds.intersect(block.bounds);
      if (overlap.isEmpty || block.bounds.isEmpty) continue;
      final fraction =
          overlap.width *
          overlap.height /
          (block.bounds.width * block.bounds.height);
      if (fraction > best &&
          (fraction >= .5 || bounds.contains(block.bounds.center))) {
        best = fraction;
        owner = index;
      }
    }
    if (owner == null) {
      order.add((bubble: null, block: block));
    } else {
      if (!grouped.containsKey(owner)) order.add((bubble: owner, block: block));
      (grouped[owner] ??= []).add(block);
    }
  }
  final blocks = [
    for (final entry in order)
      entry.bubble == null
          ? entry.block
          : OcrBlock(
              grouped[entry.bubble]!.map((b) => b.text).join('\n'),
              bubbles[entry.bubble!].bounds,
            ),
  ];
  return OcrDocument(
    document.width,
    document.height,
    blocks.map((b) => b.text).join('\n\n'),
    blocks,
  );
}

class BubbleDetector {
  static const modelAsset = 'assets/models/bubble_detector.onnx';
  static const modelHash =
      'bf5c96378e207e8680ba3f21b99cee2b1215f728c21ceb84ac155f90fe1edde4';
  final _work = <Future<BubbleDetections>>{};
  final _requests = <String, Future<BubbleDetections>>{};
  final _cache = <String, BubbleDetections>{};
  Future<_BubbleWorker>? _worker;
  Future<void>? _closing, _idleClosing;
  Timer? _idle;
  bool _closed = false;
  int _privateRequest = 0;

  Future<BubbleDetections> detect(Uint8List bytes, {bool cache = true}) {
    if (_closed) return Future.error(StateError('Bubble detector closed.'));
    _idle?.cancel();
    final pending = _detect(bytes, cache: cache);
    _work.add(pending);
    return pending.whenComplete(() {
      _work.remove(pending);
      if (!_closed && _work.isEmpty) {
        _idle = Timer(const Duration(minutes: 1), () {
          if (_closed || _work.isNotEmpty) return;
          final worker = _worker;
          _worker = null;
          if (worker != null) {
            _idleClosing = worker
                .then((w) => w.close())
                .catchError((Object _) {});
          }
        });
      }
    });
  }

  Future<BubbleDetections> _detect(
    Uint8List bytes, {
    required bool cache,
  }) async {
    if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) {
      throw const FormatException('Choose an image smaller than 32 MiB.');
    }
    final key = cache
        ? await compute(_digest, bytes)
        : 'private-${_privateRequest++}';
    if (_closed) throw StateError('Bubble detector closed.');
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    final existing = _requests[key];
    if (existing != null) return existing;
    if (_requests.length >= 2) {
      throw StateError('Text detection is already busy.');
    }
    final request = _infer(bytes);
    _requests[key] = request;
    try {
      final result = await request;
      if (cache && !_closed) {
        _cache[key] = result;
        while (_cache.length > 4) {
          _cache.remove(_cache.keys.first);
        }
      }
      return result;
    } finally {
      _requests.remove(key);
    }
  }

  Future<BubbleDetections> _infer(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 640,
      targetHeight: 640,
    );
    late Uint8List pixels;
    try {
      final frame = await codec.getNextFrame();
      try {
        final data = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (data == null ||
            frame.image.width != 640 ||
            frame.image.height != 640) {
          throw const FormatException('Invalid detection image.');
        }
        pixels = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
    if (_closed) throw StateError('Bubble detector closed.');
    final worker = await (_worker ??= _BubbleWorker.open());
    if (_closed) throw StateError('Bubble detector closed.');
    return worker.process(pixels);
  }

  Future<void> get settled => Future.wait(
    _work.map((future) => future.then<void>((_) {}, onError: (Object _) {})),
  );
  Future<void> close() {
    _closed = true;
    _idle?.cancel();
    return _closing ??= _stop();
  }

  Future<void> _stop() async {
    await settled;
    await _idleClosing;
    final worker = _worker;
    _worker = null;
    _cache.clear();
    if (worker != null) {
      try {
        await (await worker).close();
      } catch (_) {
        /* Failed model startup has no live worker. */
      }
    }
  }
}

String _digest(Uint8List bytes) => sha256.convert(bytes).toString();

class _BubbleWorker {
  _BubbleWorker(this.isolate, this.port);
  final Isolate isolate;
  final SendPort port;
  Future<void>? _closing;
  static Future<_BubbleWorker> open() async {
    final asset = await rootBundle.load(BubbleDetector.modelAsset);
    final model = asset.buffer.asUint8List(
      asset.offsetInBytes,
      asset.lengthInBytes,
    );
    if (await compute(_digest, model) != BubbleDetector.modelHash) {
      throw const FormatException('The detection model is incomplete.');
    }
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_bubbleMain, (
      TransferableTypedData.fromList([model]),
      ready.sendPort,
    ));
    try {
      final result = await ready.first.timeout(const Duration(seconds: 30));
      if (result is! SendPort) throw StateError(result.toString());
      return _BubbleWorker(isolate, result);
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      ready.close();
    }
  }

  Future<BubbleDetections> process(Uint8List pixels) async {
    if (_closing != null) throw StateError('Bubble detector closed.');
    final reply = ReceivePort();
    port.send((
      'infer',
      TransferableTypedData.fromList([pixels]),
      reply.sendPort,
    ));
    try {
      final result = await reply.first.timeout(const Duration(seconds: 60));
      if (result is! (List<List<double>>, double)) {
        throw StateError(result.toString());
      }
      return BubbleDetections([
        for (final box in result.$1)
          BubbleBox(ui.Rect.fromLTRB(box[0], box[1], box[2], box[3]), box[4]),
      ], result.$2);
    } finally {
      reply.close();
    }
  }

  Future<void> close() => _closing ??= _stop();
  Future<void> _stop() async {
    final reply = ReceivePort();
    port.send(('close', null, reply.sendPort));
    try {
      await reply.first.timeout(const Duration(seconds: 30));
    } finally {
      reply.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }
}

Future<void> _bubbleMain((TransferableTypedData, SendPort) message) async {
  OrtSession? session;
  OrtSessionOptions? options;
  SendPort? closedReply;
  var initialized = false;
  try {
    OrtEnv.instance.init();
    initialized = true;
    final telemetry = OrtEnv.instance.ortApiPtr.ref.DisableTelemetryEvents
        .cast<
          ffi.NativeFunction<
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
          >
        >()
        .asFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
        >()(OrtEnv.instance.ptr.cast());
    OrtStatus.checkOrtStatus(telemetry.cast());
    options = OrtSessionOptions()
      ..setIntraOpNumThreads(2)
      ..setInterOpNumThreads(1)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    session = OrtSession.fromBuffer(
      message.$1.materialize().asUint8List(),
      options,
    );
    final port = ReceivePort();
    message.$2.send(port.sendPort);
    await for (final raw in port) {
      final (command, data, reply) =
          raw as (String, TransferableTypedData?, SendPort);
      if (command == 'close') {
        port.close();
        closedReply = reply;
        break;
      }
      try {
        final result = decodeBubbleBoxes(
          predictBubblePixels(session, data!.materialize().asUint8List()),
        );
        reply.send((
          [
            for (final box in result.boxes)
              [
                box.bounds.left,
                box.bounds.top,
                box.bounds.right,
                box.bounds.bottom,
                box.confidence,
              ],
          ],
          result.maxScore,
        ));
      } catch (error) {
        reply.send(error.toString());
      }
    }
  } catch (error) {
    message.$2.send(error.toString());
  } finally {
    session?.release();
    options?.release();
    if (initialized) OrtEnv.instance.release();
    closedReply?.send(true);
  }
}

@visibleForTesting
Float32List predictBubblePixels(OrtSession session, Uint8List rgba) {
  const plane = 640 * 640;
  if (rgba.length != plane * 4) {
    throw const FormatException('Invalid detection image.');
  }
  final data = Float32List(plane * 3);
  for (var i = 0; i < plane; i++) {
    for (var channel = 0; channel < 3; channel++) {
      data[channel * plane + i] = rgba[i * 4 + channel] / 255;
    }
  }
  final input = OrtValueTensor.createTensorWithDataList(data, [1, 3, 640, 640]);
  final run = OrtRunOptions();
  List<OrtValue?>? outputs;
  try {
    outputs = session.run(run, {'pixel_values': input});
    final pointer = calloc<ffi.Pointer<ffi.Void>>();
    try {
      final status = OrtEnv.instance.ortApiPtr.ref.GetTensorMutableData
          .cast<
            ffi.NativeFunction<
              ffi.Pointer<ffi.Void> Function(
                ffi.Pointer<ffi.Void>,
                ffi.Pointer<ffi.Pointer<ffi.Void>>,
              )
            >
          >()
          .asFunction<
            ffi.Pointer<ffi.Void> Function(
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Pointer<ffi.Void>>,
            )
          >()(outputs.first!.ptr.cast(), pointer);
      OrtStatus.checkOrtStatus(status.cast());
      return Float32List.fromList(
        pointer.value.cast<ffi.Float>().asTypedList(5 * 8400),
      );
    } finally {
      calloc.free(pointer);
    }
  } finally {
    input.release();
    run.release();
    if (outputs != null) {
      for (final value in outputs) {
        value?.release();
      }
    }
  }
}
