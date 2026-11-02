import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:pdfium_dart/pdfium_dart.dart' as bindings;
import 'package:pdfrx/pdfrx.dart';
// This adapter is tied to the explicitly pinned pdfrx_engine version. Its
// public compute API runs the replacement on the existing PDFium worker.
// ignore: implementation_imports
import 'package:pdfrx_engine/src/native/pdfium.dart' as worker_pdfium;

Future<void> initializePdfRuntime() async {
  await pdfrxFlutterInitialize();
  if (!Platform.isWindows) return;
  await PdfrxEntryFunctions.instance.compute((String? modulePath) {
    if (worker_pdfium.pdfium is _WindowsPdfium) return;
    final library = ffi.DynamicLibrary.open(modulePath ?? 'pdfium.dll');
    final replacement = _WindowsPdfium(library);
    // Resolve and warm the getter before a failing document load sets Win32's
    // thread-local error. Lazy symbol resolution can clear it as well.
    replacement.FPDF_GetLastError();
    worker_pdfium.pdfium = replacement;
  }, Pdfrx.pdfiumModulePath);
}

class _WindowsPdfium extends bindings.PDFium {
  _WindowsPdfium(super.library)
    : _lastError = library
          .lookupFunction<ffi.UnsignedLong Function(), int Function()>(
            'FPDF_GetLastError',
            isLeaf: true,
          );

  final int Function() _lastError;

  // This pure, immediate native query never calls Dart or blocks. A leaf FFI
  // transition preserves the Win32 TLS error set by the preceding PDFium load.
  @override
  // ignore: non_constant_identifier_names
  int FPDF_GetLastError() => _lastError();
}
