import 'package:kmreader/core/background_downloads.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/app_controller.dart';
import 'features/auth/login_page.dart';
import 'ui/shell.dart';
import 'ui/device_lock_gate.dart';
import 'ui/strings.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    final app = await AppController.open();
    runApp(KMReaderApp(app: app));
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
  const KMReaderApp({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final language = app.language?.split('_');
      return MaterialApp(
        key: ValueKey(app.repository?.profile.id ?? 'welcome'),
        title: 'KMReader',
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        themeMode: app.theme,
        locale: language == null
            ? null
            : Locale(
                language.first,
                language.length > 1 ? language.last : null,
              ),
        supportedLocales: Strings.locales,
        localizationsDelegates: const [
          Strings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => DeviceLockGate(
          lock: app.deviceLock,
          child: child ?? const SizedBox.shrink(),
        ),
        home: app.repository == null
            ? WelcomePage(app: app)
            : AppShell(app: app, repository: app.repository!),
      );
    },
  );
}

@pragma('vm:entry-point')
Future<void> backgroundDownloadMain(List<String> arguments) =>
    runWindowsDownloadWorker(arguments);
