import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class ReaderLaunch {
  const ReaderLaunch(this.profile, this.book, {this.indexed = false});
  final String profile;
  final String book;
  final bool indexed;
  static bool get supported => Platform.isWindows || Platform.isAndroid;

  String get argument =>
      base64Url.encode(utf8.encode(jsonEncode([profile, book])));

  static ReaderLaunch? parse(List<String> arguments) {
    if (arguments.length != 2 ||
        !const [
          '--reader-window',
          '--indexed-book',
        ].contains(arguments.first)) {
      return null;
    }
    try {
      final value = jsonDecode(utf8.decode(base64Url.decode(arguments[1])));
      if (value is List &&
          value.length == 2 &&
          value.every((item) => item is String && item.isNotEmpty)) {
        return ReaderLaunch(
          value[0] as String,
          value[1] as String,
          indexed: arguments.first == '--indexed-book',
        );
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<void> openWindow() async {
    if (Platform.isAndroid) {
      await const MethodChannel('dev.levalue.kmreader/shortcuts')
          .invokeMethod<void>('openReaderWindow', argument);
      return;
    }
    if (!Platform.isWindows) return;
    final executable = Platform.resolvedExecutable;
    await Process.start(
      executable,
      ['--reader-window', argument],
      workingDirectory: p.dirname(executable),
      mode: ProcessStartMode.detached,
    );
  }
}
