import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/app_controller.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/catalog/dashboard.dart';
import 'package:kmreader/features/settings/preference_controls.dart';
import 'package:kmreader/main.dart';
import 'package:kmreader/ui/scroll_behavior.dart';
import 'package:kmreader/ui/section_scroll_view.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:kmreader/ui/theme.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../test/support/dashboard_scroll_fixture.dart';
import '../../test/widget_test.dart' show MemoryVault;

const _profile = ServerProfile(
  id: 'native-scroll',
  name: 'Scroll fixture',
  url: 'https://example.invalid',
  email: '',
  authentication: Authentication.apiKey,
);

Future<DeferredDashboardRepository> _repository(
  LocalStore store,
  Directory directory,
) async {
  final bytes = await rootBundle.load('assets/logo.png');
  return DeferredDashboardRepository(
    profile: _profile,
    store: store,
    directory: directory,
    imageBytes: bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    ),
    api: KomgaApi(
      Uri.parse(_profile.url),
      authentication: _profile.authentication,
      credential: '',
    ),
  )..setOffline(true);
}

Future<void> _data(
  WidgetTester tester,
  DeferredDashboardRepository repository,
) async {
  for (var i = 0; i < 8; i++) {
    repository.resolve();
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _up(WidgetTester tester) async {
  if (Platform.isWindows) {
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(120, 300),
        scrollDelta: Offset(0, -120),
      ),
    );
  } else {
    final touch = await tester.startGesture(const Offset(120, 300));
    await touch.moveBy(const Offset(0, 20));
    await tester.pump(const Duration(milliseconds: 16));
    await touch.moveBy(const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 16));
    await touch.up();
  }
}

void verifyNativeScrolling(IntegrationTestWidgetsFlutterBinding binding) {
  testWidgets(
    'native Dashboard reverses direction through mixed empty shelves without jumps',
    (tester) async {
      await Strings.initialize();
      final directory = await Directory.systemTemp.createTemp(
        'native-dashboard-',
      );
      final store = LocalStore(sqlite3.openInMemory());
      final repository = await _repository(store, directory);
      try {
        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const AppScrollBehavior(),
            theme: appTheme(Brightness.light),
            home: Scaffold(
              body: SafeArea(child: Dashboard(repository: repository)),
            ),
          ),
        );
        await _data(tester, repository);
        final controller = tester
            .widget<SectionScrollView>(
              find.byKey(const PageStorageKey('dashboard-scroll')),
            )
            .controller!;
        final extent = controller.position.maxScrollExtent;
        for (var i = 0; i < 20; i++) {
          controller.position.pointerScroll(180);
          await _data(tester, repository);
        }
        final calls = repository.calls;
        expect(controller.offset, greaterThan(0));
        for (var i = 0; i < 70 && controller.offset > 0; i++) {
          final before = controller.offset;
          await _up(tester);
          await _data(tester, repository);
          expect(controller.offset, lessThanOrEqualTo(before + .01));
          expect(controller.position.maxScrollExtent, extent);
        }
        expect(controller.offset, 0);
        expect(repository.calls, calls);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await repository.stopDownloadWork();
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'native settings keep pixels stationary at the upper wheel boundary',
    (tester) async {
      final store = LocalStore(sqlite3.openInMemory());
      final boundary = GlobalKey();
      Future<(String, Uint8List)> pixels() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          return (
            sha256
                .convert(
                  data.buffer.asUint8List(
                    data.offsetInBytes,
                    data.lengthInBytes,
                  ),
                )
                .toString(),
            png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
          );
        } finally {
          image.dispose();
        }
      }

      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              scrollBehavior: const AppScrollBehavior(),
              theme: appTheme(Brightness.light),
              home: PreferencePage(
                title: 'Settings',
                store: store,
                specs: [
                  for (var i = 0; i < 28; i++)
                    PreferenceSpec(
                      'option$i',
                      'Option $i',
                      false,
                      section: 'Group ${i ~/ 4}',
                      caption:
                          'Variable-height settings description. ' *
                          (i % 4 + 1),
                    ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        final extent = position.maxScrollExtent;
        position.jumpTo(extent * .6);
        await tester.pumpAndSettle();
        for (var i = 0; i < 70 && position.pixels > 0; i++) {
          final before = position.pixels;
          await _up(tester);
          await tester.pumpAndSettle();
          expect(position.pixels, lessThan(before));
          expect(position.maxScrollExtent, extent);
        }
        expect(position.pixels, 0);
        await tester.pumpAndSettle();
        // Let the legitimate desktop scrollbar fade finish before comparing
        // stationary content at the edge.
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        final baseline = await pixels();
        for (var i = 0; i < 8; i++) {
          await tester.sendEventToBinding(
            const PointerScrollEvent(
              position: Offset(120, 300),
              scrollDelta: Offset(0, -120),
            ),
          );
          await tester.pump(const Duration(milliseconds: 16));
          expect(position.pixels, 0);
          expect(
            (await pixels()).$1,
            baseline.$1,
            reason:
                'No transient repaint or geometry shift at the upper boundary',
          );
        }
        binding.reportData ??= <String, dynamic>{};
        binding.reportData!['screenshots'] ??= <dynamic>[];
        (binding.reportData!['screenshots'] as List).add({
          'screenshotName': 'settings-top-${Platform.operatingSystem}',
          'bytes': baseline.$2,
        });
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        store.close();
      }
    },
  );

  testWidgets(
    'native Appearance language picker closes before changing app locale',
    (tester) async {
      await Strings.initialize();
      final directory = await Directory.systemTemp.createTemp(
        'native-language-',
      );
      final store = LocalStore(sqlite3.openInMemory())..saveServer(_profile);
      final repository = await _repository(store, directory);
      final app = AppController(
        store: store,
        directory: directory,
        vault: MemoryVault(),
      )..repository = repository;
      app.setLanguage('en');
      app.setTheme(ThemeMode.light);
      bool? menuPresentAtChange;
      void changed() {
        if (app.language == 'it') {
          menuPresentAtChange = find
              .byType(CheckedPopupMenuItem<Object>)
              .evaluate()
              .isNotEmpty;
        }
      }

      app.addListener(changed);
      try {
        await tester.pumpWidget(KMReaderApp(app: app));
        await _data(tester, repository);
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, 'Appearance'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('preference::language')));
        await tester.pumpAndSettle();
        final menu = find.byType(SingleChildScrollView).last;
        final rect = tester.getRect(menu);
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<Object>, 'Italiano'),
        );
        for (var i = 0; i < 40 && menu.evaluate().isNotEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (menu.evaluate().isNotEmpty &&
              find.byType(CheckedPopupMenuItem<Object>).evaluate().isNotEmpty) {
            expect(tester.getRect(menu), rect);
          }
        }
        await tester.pumpAndSettle();
        expect(app.language, 'it');
        expect(menuPresentAtChange, isFalse);
        expect(find.byType(CheckedPopupMenuItem<Object>), findsNothing);
        expect(find.text('Cambia lingua'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        app.removeListener(changed);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await repository.stopDownloadWork();
        app.deviceLock.dispose();
        app.dispose();
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
