import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/catalog/dashboard.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:kmreader/ui/theme.dart';
import 'package:kmreader/ui/common.dart';
import 'package:kmreader/ui/scroll_behavior.dart';
import 'package:kmreader/features/settings/preference_controls.dart';
import 'package:sqlite3/sqlite3.dart';

import 'widget_test.dart' show FixtureRepository;
import 'support/dashboard_scroll_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await Strings.initialize();
    for (final font in jsonDecode(
      await rootBundle.loadString('FontManifest.json'),
    ) as List) {
      final loader = FontLoader(font['family'] as String);
      for (final item in font['fonts'] as List) {
        loader.addFont(rootBundle.load(item['asset'] as String));
      }
      await loader.load();
    }
    var folder = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 9; i++) {
      final file = File(
        '${folder.path}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
      );
      if (file.existsSync()) {
        await (FontLoader('Segoe UI')..addFont(
              Future.value(file.readAsBytesSync().buffer.asByteData()),
            ))
            .load();
        break;
      }
      folder = folder.parent;
    }
  });
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'mixed Dashboard can return through recycled empty shelves to the top on $platform',
      (tester) async {
        tester.view.physicalSize = Size(
          platform == TargetPlatform.android ? 390 : 1100,
          740,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final dir = Directory.systemTemp.createTempSync('dashboard-scroll-');
        final store = LocalStore(sqlite3.openInMemory());
        const profile = ServerProfile(
          id: 'scroll',
          name: 'Fixture',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.apiKey,
        );
        final repo = DeferredDashboardRepository(
          profile: profile,
          store: store,
          directory: dir,
          imageBytes: FixtureRepository.bytes,
          api: KomgaApi(
            Uri.parse(profile.url),
            authentication: profile.authentication,
            credential: '',
          ),
        );
        addTearDown(() {
          repo.dispose();
          store.close();
          dir.deleteSync(recursive: true);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(body: Dashboard(repository: repo)),
          ),
        );
        await tester.runAsync(() async {
          for (final width in [128, 256, 512, 1024]) {
            await precacheImage(
              ResizeImage(MemoryImage(FixtureRepository.bytes), width: width),
              tester.element(find.byType(Dashboard)),
            );
          }
        });
        final scrollable = find
            .descendant(
              of: find.byKey(const PageStorageKey('dashboard-scroll')),
              matching: find.byType(Scrollable),
            )
            .first;
        final position = tester.state<ScrollableState>(scrollable).position;
        Future<void> settleData() async {
          for (var i = 0; i < 8; i++) {
            repo.resolve();
            await tester.pump(const Duration(milliseconds: 20));
          }
        }

        await settleData();
        for (var i = 0; i < 30; i++) {
          position.pointerScroll(180);
          await settleData();
        }
        final loadedCalls = repo.calls;
        expect(position.pixels, greaterThan(500));
        for (var i = 0; i < 55 && position.pixels > 0; i++) {
          final before = position.pixels;
          if (platform == TargetPlatform.windows) {
            await tester.sendEventToBinding(
              const PointerScrollEvent(
                position: Offset(120, 300),
                scrollDelta: Offset(0, -100),
              ),
            );
          } else {
            final gesture = await tester.startGesture(const Offset(120, 300));
            await gesture.moveBy(const Offset(0, 20));
            await tester.pump(const Duration(milliseconds: 16));
            await gesture.moveBy(const Offset(0, 100));
            await tester.pump(const Duration(milliseconds: 16));
            await gesture.up();
          }
          await settleData();
          expect(
            position.pixels,
            lessThanOrEqualTo(before + .01),
            reason: 'Upward input must not move the viewport down when an empty shelf reappears',
          );
        }
        expect(
          position.pixels,
          0,
          reason: 'Repeated upward input must reach the top',
        );
        expect(
          repo.calls,
          loadedCalls,
          reason: 'Returning to resolved sections must retain their data and heights',
        );
        for (var i = 0; i < 12; i++) {
          await tester.sendEventToBinding(
            const PointerScrollEvent(
              position: Offset(120, 300),
              scrollDelta: Offset(0, -120),
            ),
          );
          await tester.pump(const Duration(milliseconds: 16));
          expect(position.pixels, 0);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(repo.stopDownloadWork);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
  testWidgets(
    'language choice fades without resizing and applies only after dismissal',
    (tester) async {
      tester.view.physicalSize = const Size(390, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String current = 'en';
      final choices = <Object, String>{
        'system': 'System',
        'en': 'English',
        'it': 'Italiano',
        'de': 'Deutsch',
        'fr': 'Français',
        'ja': '日本語',
        'ko': '한국어',
        'zh_CN': '简体中文',
        'zh_TW': '繁體中文',
        'ru': 'Русский',
        'es': 'Español',
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: StatefulBuilder(
            builder: (context, update) {
              return Scaffold(
                body: Center(
                  child: Builder(
                    builder: (anchor) {
                      return TextButton(
                        child: Text('Language: $current'),
                        onPressed: () async {
                          final chosen = await chooseValue<Object>(
                            anchor,
                            title: 'Language',
                            selected: current,
                            choices: choices,
                            anchored: true,
                          );
                          if (chosen != null && context.mounted) {
                            update(() => current = chosen as String);
                          }
                        },
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Language: en'));
      await tester.pumpAndSettle();
      final menu = find.byType(SingleChildScrollView).last;
      final rect = tester.getRect(menu);
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<Object>, 'Italiano'),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        current,
        'en',
        reason: 'Localizations must not rebuild the app during the closing animation',
      );
      expect(tester.getRect(menu), rect);
      await tester.pump(const Duration(milliseconds: 50));
      expect(current, 'en');
      expect(tester.getRect(menu), rect);
      await tester.pumpAndSettle();
      expect(current, 'it');
      expect(find.byType(CheckedPopupMenuItem<Object>), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'settings keep their geometry at the top and through upward scrolling on $platform',
      (tester) async {
        tester.view.physicalSize = Size(
          platform == TargetPlatform.android ? 390 : 1100,
          740,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = LocalStore(sqlite3.openInMemory());
        addTearDown(store.close);
        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const AppScrollBehavior(),
            theme: appTheme(Brightness.light),
            home: PreferencePage(
              title: 'Settings',
              store: store,
              specs: [
                for (var i = 0; i < 28; i++)
                  PreferenceSpec(
                    'test$i',
                    'Option $i',
                    false,
                    section: 'Section ${i ~/ 4}',
                    caption:
                        'A variable height setting description. ' * (i % 4 + 1),
                  ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scrolling = find.byType(Scrollable).first;
        final position = tester.state<ScrollableState>(scrolling).position;
        final extent = position.maxScrollExtent;
        final top = find.text('Option 0');
        final rect = tester.getRect(top);
        expect(find.byType(StretchingOverscrollIndicator), findsNothing);
        expect(find.byType(GlowingOverscrollIndicator), findsNothing);
        for (var i = 0; i < 15; i++) {
          await tester.sendEventToBinding(
            const PointerScrollEvent(
              position: Offset(110, 220),
              scrollDelta: Offset(0, -120),
            ),
          );
          await tester.pump(const Duration(milliseconds: 16));
          expect(position.pixels, 0);
          expect(tester.getRect(top), rect);
        }
        position.jumpTo(extent * .6);
        await tester.pumpAndSettle();
        for (var i = 0; i < 60 && position.pixels > 0; i++) {
          final before = position.pixels;
          await tester.sendEventToBinding(
            const PointerScrollEvent(
              position: Offset(110, 220),
              scrollDelta: Offset(0, -120),
            ),
          );
          await tester.pump(const Duration(milliseconds: 16));
          expect(position.pixels, lessThan(before));
          expect(position.maxScrollExtent, extent);
        }
        expect(position.pixels, 0);
        expect(tester.getRect(top), rect);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
  testWidgets('long picker supports Escape and reduced-motion selection', (
    tester,
  ) async {
    for (final reduced in [false, true]) {
      Object? answer = 'pending';
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(reduced),
          theme: appTheme(Brightness.light),
          home: Builder(
            builder: (context) {
              return MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reduced),
                child: Scaffold(
                  body: Center(
                    child: Builder(
                      builder: (anchor) {
                        return TextButton(
                          child: const Text('Open choices'),
                          onPressed: () async {
                            answer = await chooseValue<Object>(
                              anchor,
                              title: 'Choices',
                              selected: '0',
                              anchored: true,
                              choices: {
                                for (var i = 0; i < 11; i++) '$i': 'Choice $i',
                              },
                            );
                          },
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Open choices'));
      await tester.pumpAndSettle();
      if (reduced) {
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<Object>, 'Choice 1'),
        );
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      }
      await tester.pumpAndSettle();
      expect(answer, reduced ? '1' : null);
      expect(find.byType(CheckedPopupMenuItem<Object>), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
