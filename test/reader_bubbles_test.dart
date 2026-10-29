import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/core/translation.dart';
import 'package:kmreader/features/reader/bubble_detector.dart';
import 'package:kmreader/features/reader/reader_ocr.dart';
import 'package:kmreader/features/reader/reader_text_page.dart';
import 'package:sqlite3/sqlite3.dart';

import 'translation_test.dart' show Vault;

class _Ocr extends ReaderOcr {
  _Ocr() : super(Directory('.'));
  final cacheFlags = <bool>[];
  @override
  Future<List<String>> languages() async => ['latin'];
  @override
  Future<OcrDocument> recognize(
    Uint8List bytes,
    String language, {
    bool cache = true,
  }) async {
    cacheFlags.add(cache);
    return OcrDocument(100, 200, 'Hello\nCaption\nworld', [
      OcrBlock('Hello', const Rect.fromLTWH(.1, .1, .2, .1)),
      OcrBlock('Caption', const Rect.fromLTWH(.7, .8, .2, .1)),
      OcrBlock('world', const Rect.fromLTWH(.1, .25, .2, .1)),
    ]);
  }
}

class _Detector extends BubbleDetector {
  final cacheFlags = <bool>[];
  final first = Completer<BubbleDetections>();
  @override
  Future<BubbleDetections> detect(Uint8List bytes, {bool cache = true}) {
    cacheFlags.add(cache);
    if (cacheFlags.length == 1) return first.future;
    return Future.error(StateError('Model unavailable'));
  }
}

void main() {
  for (final width in [320.0, 1280.0]) {
    testWidgets(
      'bubble opt-in, pending guard and OCR fallback fit $width pixels',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = LocalStore(sqlite3.openInMemory());
        addTearDown(store.close);
        final ocr = _Ocr(), detector = _Detector();
        final incognito = width == 320;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.3)),
              child: child!,
            ),
            home: ReaderTextPage(
              bytes: Uint8List.fromList([1]),
              ocr: ocr,
              detector: detector,
              providers: TranslationProviders(store, vault: Vault()),
              title: 'Comic',
              incognito: incognito,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Hello\nCaption\nworld'), findsOneWidget);
        expect(detector.cacheFlags, isEmpty);
        Future<void> toggle() async {
          await tester.tap(find.byType(PopupMenuButton<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(CheckedPopupMenuItem<String>));
          await tester.pump(const Duration(milliseconds: 400));
        }

        await toggle();
        expect(store.setting<bool>('ocrGroupBubbles'), true);
        expect(detector.cacheFlags, [!incognito]);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester
              .widget<CheckedPopupMenuItem<String>>(
                find.byType(CheckedPopupMenuItem<String>),
              )
              .enabled,
          false,
        );
        await tester.tapAt(const Offset(4, 400));
        await tester.pump(const Duration(milliseconds: 400));
        detector.first.complete(
          BubbleDetections(const [
            BubbleBox(Rect.fromLTWH(.05, .05, .4, .4), .9),
          ], .9),
        );
        await tester.pumpAndSettle();
        expect(find.text('Hello\nworld\n\nCaption'), findsOneWidget);
        await toggle();
        await tester.pumpAndSettle();
        expect(find.text('Hello\nCaption\nworld'), findsOneWidget);
        await toggle();
        await tester.pumpAndSettle();
        expect(find.text('Hello\nCaption\nworld'), findsOneWidget);
        expect(
          find.text(
            'Bubble detection failed. System OCR regions are still available.',
          ),
          findsOneWidget,
        );
        expect(ocr.cacheFlags, List.filled(4, !incognito));
        expect(detector.cacheFlags, List.filled(2, !incognito));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      },
    );
  }
}
