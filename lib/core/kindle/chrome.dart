import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'client.dart';

/// The normal profile is opened by Chrome itself. No profile files, cookies,
/// debugging ports or password databases are accessed by KMReader.
Future<void> openKindleChrome(Uri url) async {
  if (Platform.isWindows) {
    for (final root in ['PROGRAMFILES', 'PROGRAMFILES(X86)', 'LOCALAPPDATA']) {
      final directory = Platform.environment[root];
      if (directory == null) continue;
      final chrome = File(
        p.join(directory, 'Google', 'Chrome', 'Application', 'chrome.exe'),
      );
      if (await chrome.exists()) {
        await Process.start(chrome.path, [
          '--new-window',
          url.toString(),
        ], mode: ProcessStartMode.detached);
        return;
      }
    }
  }
  if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
    throw const KindleFailure('browser_unavailable');
  }
}
