import 'package:kmreader/core/background_downloads.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/app_controller.dart';
import 'core/download_notifications.dart';
import 'core/reader_launch.dart';
import 'features/reader/reader_window_page.dart';
import 'features/auth/login_page.dart';
import 'ui/shell.dart';
import 'ui/device_lock_gate.dart';
import 'ui/strings.dart';
import 'ui/theme.dart';
import 'ui/scroll_behavior.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['Kindle conversion worker (kfxlib)'],
      '${await rootBundle.loadString('assets/kindle/NOTICE.md')}\n${await rootBundle.loadString('assets/kindle/COPYING')}',
    );
  });
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'KMReader (upstream)',
    ], await rootBundle.loadString('LICENSE'));
    for (final (name, file) in [
      ('Epub.js', 'EPUBJS-LICENSE'),
      ('JSZip', 'JSZIP-LICENSE'),
      ('EPUB browser dependencies', 'THIRD-PARTY-NOTICES'),
    ]) {
      yield LicenseEntryWithLineBreaks([
        name,
      ], await rootBundle.loadString('assets/epub/$file'));
    }
  });
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Waifu2x portable model',
    ], await rootBundle.loadString('assets/models/LICENSE'));
    yield LicenseEntryWithLineBreaks(
      ['Comic bubble detector'],
      '${await rootBundle.loadString('assets/models/BUBBLE-LICENSE')}\n${await rootBundle.loadString('assets/models/BUBBLE-NOTICE')}',
    );
  });
  await Strings.initialize();
  try {
    final launch = ReaderLaunch.parse(arguments);
    final app = await AppController.open(standaloneReader: launch != null);
    if (launch == null &&
        app.store.setting<bool>(DownloadNotifications.setting) == true) {
      await DownloadNotifications.initialize();
      final requested = DownloadNotifications.pending;
      final profile = app.visibleServers
          .where((profile) => profile.id == requested && !profile.isProtected)
          .firstOrNull;
      if (app.repository == null && profile != null) {
        try {
          await app.activate(profile);
        } on Exception {
          // The regular server picker can recover unavailable credentials.
        }
      }
    }
    runApp(KMReaderApp(app: app, launch: launch));
  } catch (error) {
    runApp(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: SelectableText(
                'KMReader could not initialize local storage.\n$error',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class KMReaderApp extends StatelessWidget {
  const KMReaderApp({super.key, required this.app, this.launch});
  final AppController app;
  final ReaderLaunch? launch;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      return MaterialApp(
        key: ValueKey(
          launch != null
              ? 'readerWindow'
              : app.repository?.profile.id ?? 'welcome',
        ),
        title: 'KMReader',
        scrollBehavior: const AppScrollBehavior(),
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        themeMode: app.theme,
        locale: Strings.preferredLocale(app.language),
        supportedLocales: Strings.locales,
        localizationsDelegates: const [
          Strings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => DeviceLockGate(
          lock: app.deviceLock,
          requireAuthentication: app.protectedServerVisible,
          privacyProtection:
              app.store.setting<bool>('privacyProtection') == true,
          child: child ?? const SizedBox.shrink(),
        ),
        home: launch != null
            ? ReaderWindowPage(app: app, launch: launch!)
            : app.repository == null
            ? WelcomePage(app: app)
            : AppShell(app: app, repository: app.repository!),
      );
    },
  );
}

@pragma('vm:entry-point')
Future<void> backgroundDownloadMain(List<String> arguments) =>
    runWindowsDownloadWorker(arguments);
