import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'reader_launch.dart';
import 'store.dart';

class SystemLibraryIndex {
  SystemLibraryIndex(this.store);
  final LocalStore store;
  static const setting = 'systemLibraryIndex';
  static const _android = MethodChannel('dev.levalue.kmreader/library_index');
  Future<void> _work = Future.value();
  String? _lastPublished;

  bool get supported => Platform.isWindows || Platform.isAndroid;

  Future<void> refresh() {
    if (!supported || store.setting<bool>(setting) == null) {
      return Future.value();
    }
    final update = _work.then((_) => _publish());
    _work = update.then<void>((_) {}, onError: (Object _) {});
    return update;
  }

  Future<void> _publish() async {
    final visible =
        store.setting<bool>(setting) == true &&
        store.setting<bool>('privacyProtection') != true &&
        store.setting<bool>('deviceLock') != true;
    final entries = <Json>[
      if (visible)
        for (final profile in store.servers)
          if (!profile.isProtected && !profile.isKindle)
            for (final row in store.downloads(profile.id))
              if (row['status'] == 'ready')
                _entry(profile.id, Book(object(row['book']))),
    ];
    entries.removeWhere((entry) => text(entry['title']).trim().isEmpty);
    entries.sort((a, b) => text(a['key']).compareTo(text(b['key'])));
    final snapshot = jsonEncode(entries);
    if (snapshot == _lastPublished) return;
    _lastPublished = null;
    if (Platform.isAndroid) {
      await _android.invokeMethod<void>('publish', snapshot);
    } else {
      await _windows(snapshot);
    }
    _lastPublished = snapshot;
  }

  Json _entry(String profile, Book book) {
    final launch = ReaderLaunch(profile, book.id);
    final key = sha256
        .convert(utf8.encode(launch.argument))
        .toString()
        .substring(0, 16);
    final title = book.title.isEmpty ? book.id : book.title;
    final safeName = title
        .replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001f]'), ' ')
        .trim();
    return {
      'key': key,
      'title': title,
      'name': String.fromCharCodes(safeName.runes.take(90)).trim(),
      'argument': launch.argument,
    };
  }

  Future<void> _windows(String entries) async {
    final script = Uint8List(_writeWindowsLinks.length * 2);
    final bytes = ByteData.sublistView(script);
    for (var i = 0; i < _writeWindowsLinks.length; i++) {
      bytes.setUint16(i * 2, _writeWindowsLinks.codeUnitAt(i), Endian.little);
    }
    final executable = Platform.resolvedExecutable;
    final process = await Process.start(
      p.join(
        Platform.environment['SystemRoot'] ?? r'C:\Windows',
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      ),
      [
        '-NoProfile',
        '-NonInteractive',
        '-EncodedCommand',
        base64Encode(script),
      ],
    );
    final output = Future.wait([
      process.stdout.drain<void>(),
      process.stderr.drain<void>(),
    ]);
    process.stdin.add(
      utf8.encode(
        jsonEncode({
          'executable': executable,
          'workingDirectory': p.dirname(executable),
          'entries': jsonDecode(entries),
        }),
      ),
    );
    await process.stdin.close();
    final status = await process.exitCode;
    await output;
    if (status != 0) {
      throw StateError('Could not update the Windows search index.');
    }
  }
}

const _writeWindowsLinks = r'''
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
$inputData = [Console]::In.ReadToEnd() | ConvertFrom-Json
$programs = [Environment]::GetFolderPath('Programs')
if ([string]::IsNullOrEmpty($programs)) { throw 'Start menu unavailable' }
$folder = Join-Path $programs 'KMReader Offline Library'
$entries = @($inputData.entries)
$wanted = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($entries.Count -gt 0) {
  [IO.Directory]::CreateDirectory($folder) | Out-Null
  $shell = New-Object -ComObject WScript.Shell
  foreach ($entry in $entries) {
    $name = "KMReader - $($entry.name) [$($entry.key)].lnk"
    $file = Join-Path $folder $name
    [void]$wanted.Add($name)
    $link = $shell.CreateShortcut($file)
    $link.TargetPath = $inputData.executable
    $link.Arguments = "--indexed-book $($entry.argument)"
    $link.WorkingDirectory = $inputData.workingDirectory
    $link.Description = $entry.title
    $link.Save()
  }
}
if ([IO.Directory]::Exists($folder)) {
  foreach ($file in [IO.Directory]::EnumerateFiles($folder, '*.lnk')) {
    $name = [IO.Path]::GetFileName($file)
    if ($name -match '^KMReader - .* \[[0-9a-f]{16}\]\.lnk$' -and !$wanted.Contains($name)) {
      [IO.File]::Delete($file)
    }
  }
}
''';
