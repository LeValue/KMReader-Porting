import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import '../../core/cache.dart';

class PageUpscaler {
  PageUpscaler(this.directory);
  final Directory directory;
  Future<_UpscaleWorker>? _worker;
  final _requests = <String, Future<Uint8List?>>{};
  bool _closed = false;
  String? error;
  static const modelAsset = 'assets/models/waifu2x_photo_noise0_scale2x.onnx';
  static const modelHash =
      '3122f9237c9a55220bdcee6cf530e49214e57e68f36c1119d9137f7ee28e4558';
  Future<Uint8List?> enhance(
    Uint8List bytes,
    ui.Size screen, {
    double threshold = 1.05,
  }) async {
    if (_closed) return null;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width, h = descriptor.height;
      if (!shouldEnhance(w, h, screen.width, screen.height, threshold)) {
        return null;
      }
      // Bound the complete output raster, in addition to per-tile inference.
      if (w * h > 2 * 1024 * 1024) return null;
      final id = await compute(_imageHash, bytes);
      final existing = _requests[id];
      if (existing != null) return await existing;
      if (_requests.length >= 2) return null;
      final future = _enhance(bytes, id, w, h);
      _requests[id] = future;
      try {
        return await future;
      } finally {
        _requests.remove(id);
      }
    } catch (failure) {
      error = failure.toString();
      return null;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static bool shouldEnhance(
    int width,
    int height,
    double screenWidth,
    double screenHeight,
    double threshold,
  ) =>
      width > 0 &&
      height > 0 &&
      screenWidth.isFinite &&
      screenHeight.isFinite &&
      math.min(screenWidth / width, screenHeight / height) >
          math.max(1, threshold);
  Future<Uint8List?> _enhance(
    Uint8List bytes,
    String id,
    int width,
    int height,
  ) async {
    try {
      final file = File('${directory.path}/upscaled/$modelHash-$id.png');
      if (await file.exists()) {
        await file.setLastModified(DateTime.now());
        return await file.readAsBytes();
      }
      final codec = await ui.instantiateImageCodec(bytes);
      late Uint8List pixels;
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          final raw = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          pixels = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
      final worker = await (_worker ??= _UpscaleWorker.open());
      if (_closed) return null;
      final result = await worker.process(pixels, width, height);
      if (_closed) return null;
      final ready = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        result,
        width * 2,
        height * 2,
        ui.PixelFormat.rgba8888,
        ready.complete,
      );
      final image = await ready.future;
      late Uint8List png;
      try {
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        png = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        image.dispose();
      }
      if (!_closed) {
        try {
          await file.parent.create(recursive: true);
          final temporary = File('${file.path}.part');
          await temporary.writeAsBytes(png, flush: true);
          await temporary.rename(file.path);
          await trimMediaCache(file.parent, 256 * 1024 * 1024);
        } on FileSystemException {
          /* Optional cache. */
        }
      }
      return png;
    } catch (failure) {
      error = failure.toString();
      return null;
    }
  }

  void close() {
    _closed = true;
    final worker = _worker;
    if (worker != null) {
      unawaited(
        worker.then((value) => value.close()).catchError((Object _) {}),
      );
    }
  }
}

String _imageHash(Uint8List bytes) => sha256.convert(bytes).toString();

class _UpscaleWorker {
  _UpscaleWorker(this.isolate, this.port);
  final Isolate isolate;
  final SendPort port;
  Future<void>? _closing;
  static Future<_UpscaleWorker> open() async {
    final asset = await rootBundle.load(PageUpscaler.modelAsset);
    final model = asset.buffer.asUint8List(
      asset.offsetInBytes,
      asset.lengthInBytes,
    );
    if (await compute(_imageHash, model) != PageUpscaler.modelHash) {
      throw const FormatException('The upscaling model is incomplete.');
    }
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_upscaleMain, (
      TransferableTypedData.fromList([model]),
      ready.sendPort,
    ));
    try {
      final result = await ready.first.timeout(const Duration(seconds: 30));
      if (result is! SendPort) throw StateError(result.toString());
      return _UpscaleWorker(isolate, result);
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      ready.close();
    }
  }

  Future<Uint8List> process(Uint8List pixels, int width, int height) async {
    if (_closing != null) throw StateError('Upscaler closed.');
    final reply = ReceivePort();
    port.send((
      'infer',
      (TransferableTypedData.fromList([pixels]), width, height),
      reply.sendPort,
    ));
    try {
      final result = await reply.first.timeout(const Duration(minutes: 2));
      if (result is! TransferableTypedData) throw StateError(result.toString());
      return result.materialize().asUint8List();
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

Future<void> _upscaleMain((TransferableTypedData, SendPort) message) async {
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
      final (command, value, reply) = raw as (String, Object?, SendPort);
      if (command == 'close') {
        port.close();
        closedReply = reply;
        break;
      }
      try {
        final (data, width, height) =
            value as (TransferableTypedData, int, int);
        final pixels = data.materialize().asUint8List();
        final result = upscalePixels(session, pixels, width, height);
        reply.send(TransferableTypedData.fromList([result]));
      } catch (failure) {
        reply.send(failure.toString());
      }
    }
  } catch (failure) {
    message.$2.send(failure.toString());
  } finally {
    session?.release();
    options?.release();
    if (initialized) OrtEnv.instance.release();
    closedReply?.send(true);
  }
}

/// The source network uses a 7-pixel context and produces 2x opaque RGB.
/// No tile overlaps are blended: each output uses the original neighboring
/// pixels, which prevents seams and avoids repeated processing of edge tiles.
@visibleForTesting
Uint8List upscalePixels(
  OrtSession session,
  Uint8List rgba,
  int width,
  int height,
) {
  if (width < 1 ||
      height < 1 ||
      rgba.length != width * height * 4 ||
      width * height > 2 * 1024 * 1024) {
    throw const FormatException('Unsupported upscaling image size.');
  }
  final result = Uint8List(width * height * 16);
  final run = OrtRunOptions();
  try {
    for (var top = 0; top < height; top += 142) {
      for (var left = 0; left < width; left += 142) {
        final w = math.min(142, width - left),
            h = math.min(142, height - top),
            inputWidth = w + 14,
            inputHeight = h + 14;
        final plane = inputWidth * inputHeight, input = Float32List(plane * 3);
        for (var y = 0; y < inputHeight; y++) {
          final sy = top + y - 7, py = sy.clamp(0, height - 1);
          for (var x = 0; x < inputWidth; x++) {
            final sx = left + x - 7,
                px = sx.clamp(0, width - 1),
                source = (py * width + px) * 4,
                target = y * inputWidth + x;
            final eta = sx < 0 || sy < 0 || sx >= width || sy >= height
                ? 0.0
                : .00196078411;
            for (var channel = 0; channel < 3; channel++) {
              input[channel * plane + target] =
                  rgba[source + channel] / 255 + eta;
            }
          }
        }
        final tensor = OrtValueTensor.createTensorWithDataList(input, [
          1,
          3,
          inputHeight,
          inputWidth,
        ]);
        List<OrtValue?>? outputs;
        try {
          outputs = session.run(run, {'input': tensor});
          final value = outputs.first!;
          final pointer = calloc<ffi.Pointer<ffi.Void>>();
          late Float32List data;
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
                >()(value.ptr.cast(), pointer);
            OrtStatus.checkOrtStatus(status.cast());
            data = pointer.value.cast<ffi.Float>().asTypedList(3 * w * h * 4);
          } finally {
            calloc.free(pointer);
          }
          final outWidth = w * 2,
              outHeight = h * 2,
              outPlane = outWidth * outHeight;
          for (var y = 0; y < outHeight; y++) {
            for (var x = 0; x < outWidth; x++) {
              final target = ((top * 2 + y) * width * 2 + left * 2 + x) * 4,
                  index = y * outWidth + x;
              for (var channel = 0; channel < 3; channel++) {
                result[target +
                    channel] = (data[channel * outPlane + index] * 255)
                    .clamp(0, 255)
                    .toInt();
              }
              result[target + 3] = 255;
            }
          }
        } finally {
          tensor.release();
          if (outputs != null) {
            for (final value in outputs) {
              value?.release();
            }
          }
        }
      }
    }
    return result;
  } finally {
    run.release();
  }
}

class UpscaledPageImage extends StatefulWidget {
  const UpscaledPageImage({
    super.key,
    required this.bytes,
    required this.upscaler,
    required this.enabled,
    required this.screen,
    this.threshold = 1.05,
    required this.builder,
  });
  final Uint8List bytes;
  final PageUpscaler upscaler;
  final bool enabled;
  final ui.Size screen;
  final double threshold;
  final Widget Function(Uint8List) builder;
  @override
  State<UpscaledPageImage> createState() => _UpscaledPageImageState();
}

class _UpscaledPageImageState extends State<UpscaledPageImage> {
  Uint8List? _enhanced;
  Timer? _timer;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(UpscaledPageImage old) {
    super.didUpdateWidget(old);
    if (old.bytes != widget.bytes ||
        old.enabled != widget.enabled ||
        old.screen != widget.screen ||
        old.threshold != widget.threshold) {
      _enhanced = null;
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    final generation = ++_generation;
    if (!widget.enabled) return;
    _timer = Timer(const Duration(milliseconds: 300), () async {
      final value = await widget.upscaler.enhance(
        widget.bytes,
        widget.screen,
        threshold: widget.threshold,
      );
      if (mounted && generation == _generation && value != null) {
        setState(() => _enhanced = value);
      }
    });
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(_enhanced ?? widget.bytes);
}
