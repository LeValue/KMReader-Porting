import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/app_controller.dart';
import 'package:kmreader/core/local_library.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/auth/login_page.dart';
import 'package:kmreader/features/local/local_library_page.dart';
import 'package:kmreader/features/reader/reader_page.dart';
import 'package:kmreader/features/reader/page_transition.dart';
import 'package:sqlite3/sqlite3.dart';

void verifyNativeLocalLibrary() {
  testWidgets('serverless local comic import, reading and final-page guard', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'native-local-library-',
    );
    final store = LocalStore(sqlite3.open('${directory.path}/local.sqlite'))
      ..setSetting('showKeyboardHelpOverlay', false);
    final app = AppController(
      store: store,
      directory: directory,
      vault: const SecureVault(),
    );
    try {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(Colors.green, ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(100, 150);
      picture.dispose();
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      image.dispose();
      final archive = Archive()..addFile(ArchiveFile.bytes('1.png', bytes));
      final original = File('${directory.path}/Local fixture.cbz')
        ..writeAsBytesSync(ZipEncoder().encode(archive));
      final imported = await app.localLibrary.importFile(XFile(original.path));
      await tester.pumpWidget(MaterialApp(home: WelcomePage(app: app)));
      await tester.tap(find.text('Local Books'));
      await tester.pumpAndSettle();
      expect(find.byType(LocalLibraryPage), findsOneWidget);
      await tester.tap(find.text(imported.title));
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        if (find
            .byType(RawImage)
            .evaluate()
            .any((e) => (e.widget as RawImage).image != null)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(find.byType(ReaderPage), findsOneWidget);
      final viewport = tester.getSize(find.byType(ReaderPageTransition));
      await tester.pump(const Duration(seconds: 6));
      expect(find.byTooltip('Close'), findsNothing);
      await tester.tapAt(tester.getCenter(find.byType(ReaderPageTransition)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byTooltip('Close'), findsOneWidget);
      expect(tester.getSize(find.byType(ReaderPageTransition)), viewport);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          tester
              .widgetList<CustomPaint>(find.byType(CustomPaint))
              .any((paint) => paint.painter is PageTurnPainter),
          false,
          reason: 'The final page must never create a transition overlay',
        );
      }
      expect(store.pendingCount(LocalLibrary.scope), 0);
      expect(original.existsSync(), true);
      expect(store.servers, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      app.localLibrary.dispose();
      store.close();
      await directory.delete(recursive: true);
    }
  });
}
