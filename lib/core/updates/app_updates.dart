import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show AppExitType;

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart'
    show MethodChannel, rootBundle, ServicesBinding;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_version.dart';

const updateRepository = 'LeValue/KMReader-Porting';
const updateOrigin = 'https://github.com/$updateRepository/releases/download/';

class AppUpdate {
  AppUpdate(
    this.version,
    this.build,
    this.source,
    this.url,
    this.sha256,
    this.size,
  );
  final String version, source, sha256;
  final int build, size;
  final Uri url;
  static AppUpdate parse(
    Map<String, dynamic> json,
    String platform, {
    int currentBuild = appBuildNumber,
  }) {
    final package = json['packages'] is Map ? json['packages'][platform] : null;
    final build = json['build'];
    final version = json['version'];
    final source = json['source'];
    if (json['schema'] != 1 ||
        build is! int ||
        build <= currentBuild ||
        version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        source is! String ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(source) ||
        package is! Map) {
      throw const FormatException('Metadati aggiornamento non validi');
    }
    final candidateVersion = version.split('.').map(int.parse).toList();
    final installedVersion = appVersion.split('.').map(int.parse).toList();
    for (var index = 0; index < 3; index++) {
      if (candidateVersion[index] > installedVersion[index]) break;
      if (candidateVersion[index] < installedVersion[index]) {
        throw const FormatException('Versione precedente');
      }
    }
    final url = Uri.tryParse('${package['url']}');
    final digest = package['sha256'];
    final size = package['size'];
    final suffix = platform.startsWith('android') ? '.apk' : '.zip';
    if (url == null ||
        url.scheme != 'https' ||
        url.host != 'github.com' ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        !url.toString().startsWith(updateOrigin) ||
        !url.path.endsWith(suffix) ||
        url.pathSegments.length != 6 ||
        url.pathSegments.any((s) => s == '..' || s.contains('\\')) ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        size is! int ||
        size <= 0 ||
        size > 512 * 1024 * 1024) {
      throw const FormatException('Pacchetto aggiornamento non valido');
    }
    return AppUpdate(version, build, source, url, digest, size);
  }
}

class AppUpdates {
  AppUpdates({http.Client? client}) : client = client ?? http.Client();
  final http.Client client;
  bool _closed = false;
  static bool _windowsInstallStarted = false;
  void close() {
    _closed = true;
    client.close();
  }

  Future<http.StreamedResponse> _get(Uri uri) async {
    for (var redirects = 0; redirects < 6; redirects++) {
      if (_closed) throw const HttpException('Download annullato');
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.port != 443 ||
          !(uri.host == 'api.github.com' ||
              uri.host == 'github.com' ||
              uri.host.endsWith('.githubusercontent.com'))) {
        throw const HttpException('Destinazione aggiornamento non valida');
      }
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers['User-Agent'] = 'KMReader/$appVersion';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers['location'];
        await response.stream.drain<void>();
        if (location == null) {
          throw const HttpException('Reindirizzamento non valido');
        }
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw HttpException(
          'Download non disponibile (${response.statusCode})',
        );
      }
      return response;
    }
    throw const HttpException('Troppi reindirizzamenti');
  }

  Future<dynamic> _json(Uri uri, int limit) async {
    final response = await _get(uri);
    final bytes = <int>[];
    await for (final block in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      if (bytes.length + block.length > limit) {
        throw const FormatException('Risposta aggiornamento troppo grande');
      }
      bytes.addAll(block);
    }
    return jsonDecode(utf8.decode(bytes));
  }

  Future<AppUpdate?> check(String platform) async {
    if (!['android', 'windows'].contains(platform)) return null;
    final releases = await _json(
      Uri.https('api.github.com', '/repos/$updateRepository/releases', {
        'per_page': '30',
      }),
      2 * 1024 * 1024,
    );
    if (releases is! List) {
      throw const FormatException('Elenco aggiornamenti non valido');
    }
    AppUpdate? newest;
    for (final release in releases.whereType<Map>()) {
      if (release['draft'] != false || release['assets'] is! List) continue;
      final matches = (release['assets'] as List)
          .whereType<Map>()
          .where((a) => a['name'] == 'kmreader-update.json')
          .toList();
      if (matches.isEmpty) continue;
      if (matches.length != 1) {
        throw const FormatException('Manifest duplicato');
      }
      final uri = Uri.tryParse('${matches.single['browser_download_url']}');
      if (uri == null ||
          !uri.toString().startsWith(updateOrigin) ||
          uri.host != 'github.com' ||
          uri.scheme != 'https') {
        throw const FormatException('Manifest non valido');
      }
      final json = await _json(uri, 64 * 1024);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Manifest non valido');
      }
      if (json['build'] is int && json['build'] <= appBuildNumber) continue;
      var selectedPlatform = platform;
      if (platform == 'android' &&
          (json['packages'] as Map?)?['android'] == null &&
          Platform.isAndroid) {
        final abis =
            await const MethodChannel('dev.levalue.kmreader/updates')
                .invokeListMethod<String>('supportedAbis') ??
            [];
        selectedPlatform = abis
            .map((abi) => 'android-$abi')
            .firstWhere(
              (key) => (json['packages'] as Map).containsKey(key),
              orElse: () => platform,
            );
      }
      final update = AppUpdate.parse(json, selectedPlatform);
      if (update.url.pathSegments[4] != release['tag_name']) {
        throw const FormatException('Release aggiornamento non corrispondente');
      }
      if (newest == null || update.build > newest.build) newest = update;
    }
    return newest;
  }

  Future<File> download(
    AppUpdate update,
    Directory directory,
    void Function(int, int) progress,
  ) async {
    await directory.create(recursive: true);
    final target = File(
      p.join(
        directory.path,
        '${update.sha256}${update.url.path.endsWith('.apk') ? '.apk' : '.zip'}',
      ),
    );
    if (await target.exists() &&
        await target.length() == update.size &&
        (await sha256.bind(target.openRead()).first).toString() ==
            update.sha256) {
      return target;
    }
    final partial = File('${target.path}.part');
    IOSink? sink;
    try {
      final response = await _get(update.url);
      if (response.contentLength != null &&
          response.contentLength != update.size) {
        throw const FormatException('Dimensione aggiornamento errata');
      }
      sink = partial.openWrite();
      var received = 0;
      await sink.addStream(
        response.stream.timeout(const Duration(seconds: 45)).map((bytes) {
          if (_closed) throw const HttpException('Download annullato');
          received += bytes.length;
          if (received > update.size) {
            throw const FormatException('Dimensione aggiornamento errata');
          }
          progress(received, update.size);
          return bytes;
        }),
      );
      await sink.flush();
      await sink.close();
      sink = null;
      if (received != update.size ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              update.sha256) {
        throw const FormatException('Verifica aggiornamento non riuscita');
      }
      return await partial.rename(target.path);
    } finally {
      await sink?.close();
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<bool> install(AppUpdate update, File file) async {
    if (await file.length() != update.size ||
        (await sha256.bind(file.openRead()).first).toString() !=
            update.sha256) {
      throw const FormatException('Pacchetto modificato');
    }
    if (Platform.isAndroid) {
      return await const MethodChannel('dev.levalue.kmreader/updates')
              .invokeMethod<bool>('install', {
                'path': file.path,
                'build': update.build,
                'version': update.version,
                'source': update.source,
              }) ??
          false;
    }
    if (!Platform.isWindows) {
      throw UnsupportedError('Aggiornamento non disponibile');
    }
    await inspectWindowsUpdate(file.path, update);
    if (_windowsInstallStarted) {
      throw const HttpException('Aggiornamento già in attesa del riavvio');
    }
    _windowsInstallStarted = true;
    try {
      final script = File(p.join(file.parent.path, 'windows-update.ps1'));
      await script.writeAsString(
        await rootBundle.loadString('assets/update/windows-update.ps1'),
        flush: true,
      );
      final job = File(p.join(file.parent.path, 'job-${update.build}.json'));
      await job.writeAsString(
        jsonEncode({
          'pid': pid,
          'workingDirectory': Directory.current.path,
          'archive': file.path,
          'sha256': update.sha256,
          'install': p.dirname(
            await File(Platform.resolvedExecutable).resolveSymbolicLinks(),
          ),
          'build': update.build,
          'version': update.version,
          'source': update.source,
        }),
        flush: true,
      );
      // Check write access without overwriting an existing user file.
      final probe = await Directory(p.dirname(Platform.resolvedExecutable))
          .createTemp('.kmreader-update-check-');
      try {
        await File(p.join(probe.path, 'write')).writeAsString('');
      } finally {
        await probe.delete(recursive: true);
      }
      await Process.start(
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
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
          '-JobFile',
          job.path,
        ],
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (_) {
      _windowsInstallStarted = false;
      rethrow;
    }
  }

  Future<bool> previousInstallFailed() async {
    if (!Platform.isWindows) return false;
    final directory = await storageDirectory();
    if (!await directory.exists()) return false;
    final files = await directory
        .list(followLinks: false)
        .where(
          (f) =>
              f is File &&
              RegExp(r'job-[0-9]+\.json\.result$').hasMatch(f.path),
        )
        .cast<File>()
        .toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (files.isEmpty || await files.first.length() > 65536) return false;
    try {
      final result = jsonDecode(
        (await files.first.readAsString()).replaceFirst('\uFEFF', ''),
      );
      return result is Map &&
          result['state'] == 'failed' &&
          result['build'] is int &&
          result['build'] > appBuildNumber;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestRestart() async {
    await ServicesBinding.instance.exitApplication(AppExitType.required);
  }

  Future<Directory> storageDirectory() async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'updates'),
  );
}

Future<void> inspectWindowsUpdate(String path, AppUpdate update) =>
    Isolate.run(() => validateWindowsUpdate(path, update));

void validateWindowsUpdate(String path, AppUpdate update) {
  final input = InputFileStream(path);
  try {
    final archive = ZipDecoder().decodeStream(input, verify: true);
    var total = 0;
    final names = <String>{};
    Map<String, dynamic>? source;
    for (final entry in archive.files) {
      final name = entry.name;
      if (!name.startsWith('KMReader/') ||
          name.contains('\\') ||
          name.contains(':') ||
          name.split('/').any((s) => s == '..' || s == '.') ||
          (entry.isFile && name.split('/').any((s) => s.isEmpty)) ||
          entry.isSymbolicLink ||
          !names.add(name.toLowerCase())) {
        throw const FormatException('Archivio aggiornamento non valido');
      }
      total += entry.size;
      if (total > 1024 * 1024 * 1024) {
        throw const FormatException('Archivio aggiornamento troppo grande');
      }
      if (name == 'KMReader/data/flutter_assets/assets/build/source.json') {
        source = jsonDecode(utf8.decode(entry.content)) as Map<String, dynamic>;
      }
    }
    if (!names.contains('kmreader/kmreader.exe') ||
        !names.contains('kmreader/data/app.so') ||
        !names.contains('kmreader/kindle/kmreader-kindle.exe') ||
        source?['source'] != update.source ||
        source?['version'] != update.version ||
        source?['build'] != update.build) {
      throw const FormatException('Sorgente aggiornamento non corrispondente');
    }
  } finally {
    input.closeSync();
  }
}
