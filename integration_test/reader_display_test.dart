import 'package:kmreader/core/background_downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kmreader/features/reader/reader_display.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Android cutout insets survive immersive mode and rotation',
    (tester) async {
      Widget screen({
        bool document = false,
        bool extend = false,
      }) => MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            // Deliberately reproduce OEMs that remove all Flutter safe padding.
            data: MediaQuery.of(
              context,
            ).copyWith(padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero),
            child: ReaderDisplay(
              child: Scaffold(
                appBar: document
                    ? AppBar(
                        title: const Text(
                          'EPUB / PDF title',
                          key: ValueKey('document-title'),
                        ),
                      )
                    : null,
                body: Stack(
                  children: [
                    Positioned.fill(
                      child: ReaderPageSurface(
                        extendIntoCutout: extend,
                        child: const ColoredBox(
                          key: ValueKey('page'),
                          color: Color(0xffefe5d0),
                          child: Center(
                            child: Text(
                              'Native Android reader display test',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (!document)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: ColoredBox(
                          color: Colors.black87,
                          child: ReaderSafeArea(
                            bottom: false,
                            child: Row(
                              children: [
                                IconButton(
                                  key: const ValueKey('close'),
                                  onPressed: () {},
                                  color: Colors.white,
                                  icon: const Icon(Icons.close),
                                ),
                                const Expanded(
                                  child: Text(
                                    'Comic title',
                                    key: ValueKey('title'),
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    const Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: ReaderSafeArea(
                        top: false,
                        child: SizedBox(key: ValueKey('footer'), height: 48),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpWidget(screen());
      await binding.convertFlutterSurfaceToImage();
      for (final orientation in [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
      ]) {
        await SystemChrome.setPreferredOrientations([orientation]);
        await Future<void>.delayed(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        final raw = (await ReaderDisplay.channel.invokeMapMethod<String, int>(
          'setReaderMode',
          true,
        ))!;
        await tester.pumpAndSettle();
        final media = MediaQuery.of(
          tester.element(find.byKey(const ValueKey('page'))),
        );
        final dpr = media.devicePixelRatio;
        expect(
          media.orientation,
          orientation == DeviceOrientation.portraitUp
              ? Orientation.portrait
              : Orientation.landscape,
        );
        double edge(String key) => (raw[key] ?? 0) / dpr;
        final page = tester.getRect(find.byKey(const ValueKey('page')));
        final title = tester.getRect(find.byKey(const ValueKey('title')));
        final close = tester.getRect(find.byKey(const ValueKey('close')));
        expect(
          edge('cutoutTop') + edge('cutoutLeft') + edge('cutoutRight'),
          greaterThan(0),
          reason: 'The emulator must have a real WindowManager cutout overlay enabled',
        );
        expect(page.left, closeTo(edge('cutoutLeft'), 1));
        expect(page.top, closeTo(edge('cutoutTop'), 1));
        expect(page.right, closeTo(media.size.width - edge('cutoutRight'), 1));
        expect(
          page.bottom,
          closeTo(media.size.height - edge('cutoutBottom'), 1),
        );
        expect(title.top, greaterThanOrEqualTo(edge('top') - 1));
        expect(close.left, greaterThanOrEqualTo(edge('left') - 1));
        expect(
          tester.getRect(find.byKey(const ValueKey('footer'))).bottom,
          lessThanOrEqualTo(media.size.height - edge('bottom') + 1),
        );
        await binding.takeScreenshot('comic-${orientation.name}');

        await tester.pumpWidget(screen(extend: true));
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byKey(const ValueKey('page'))), media.size);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('close'))).dx,
          greaterThanOrEqualTo(edge('left') - 1),
        );

        await tester.pumpWidget(screen(document: true));
        await tester.pumpAndSettle();
        final documentTitle = tester.getRect(
          find.byKey(const ValueKey('document-title')),
        );
        expect(documentTitle.top, greaterThanOrEqualTo(edge('top') - 1));
        expect(documentTitle.left, greaterThanOrEqualTo(edge('left') - 1));
        await binding.takeScreenshot('document-${orientation.name}');
        await tester.pumpWidget(screen());
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(appBar: AppBar(title: const Text('Reader closed'))),
        ),
      );
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(tester.view.viewPadding.top, greaterThan(0));
      expect(tester.takeException(), isNull);
      await SystemChrome.setPreferredOrientations([]);
    },
  );
}

@pragma('vm:entry-point')
Future<void> backgroundDownloadMain(List<String> arguments) =>
    runWindowsDownloadWorker(arguments);
