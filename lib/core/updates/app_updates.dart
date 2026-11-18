import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show AppExitType;

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart'
    show MethodChannel, PlatformException, rootBundle, ServicesBinding;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_version.dart';
import 'windows_update_handoff.dart';

const updateRepository = 'LeValue/KMReader-Porting';
const updateOrigin = 'https://github.com/$updateRepository/releases/download/';

// Hashing large packages must not run on the UI isolate.
Future<String> _fileDigest(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
);

/// Safe product messages: never display signed URLs, file paths or native details.
String updateFailureMessage(Object error, {required String stage}) {
  if (error is PlatformException) {
    return switch (error.code) {
      'update_signature' || 'update_invalid' => 'Android could not verify this update for the installed app. Use a project release with the same signing certificate.',
      'update_signers_unavailable' => 'Android could not read the update certificates. Try installing the official APK from the release page.',
      'update_version' => 'The update version does not match this installation. Check for updates again.',
      'update_source' || 'update_package' =>
        'The downloaded package failed verification. Download it again.',
      'update_location' =>
        'The downloaded update file is unavailable. Download it again.',
      _ => 'Unable to open the system installer. Check installation permissions and retry.',
    };
  }
  if (error is HandshakeException) {
    return 'Secure connection to the update server failed. Check the device date and system updates.';
  }
  if (error is FileSystemException) {
    return [28, 112, 122].contains(error.osError?.errorCode)
        ? 'Not enough free storage for the update. Free some space and retry.'
        : 'Unable to save the update. Check storage and file permissions, then retry.';
  }
  if (error is FormatException) {
    return stage == 'check'
        ? 'Update information could not be verified. Retry later.'
        : 'The downloaded package failed verification. Download it again.';
  }
  if (stage == 'check') {
    return 'Unable to check updates. Check your connection and retry.';
  }
  if (stage == 'install' && error is ProcessException) {
    return 'Windows could not start the update helper. Open the release page to update manually.';
  }
  if (stage == 'install') {
    return 'Unable to open the system installer. Check installation permissions and retry.';
  }
  return 'Download interrupted. Tap Install update to resume.';
}

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
  File? _windowsJob;
  void close() {
    _closed = true;
    if (_windowsJob != null) {
      _windowsJob = null;
      _windowsInstallStarted = false;
    }
    client.close();
  }

  Future<http.StreamedResponse> _get(
    Uri uri, {
    Map<String, String> headers = const {},
    Set<int> accepted = const {200},
  }) async {
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
      final abort = Completer<void>();
      final request = http.AbortableRequest(
        'GET',
        uri,
        abortTrigger: abort.future,
      )..followRedirects = false;
      request.headers.addAll(headers);
      request.headers['User-Agent'] = 'KMReader/$appVersion';
      final response = await client
          .send(request)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              if (!abort.isCompleted) abort.complete();
              throw TimeoutException('Update request timed out');
            },
          );
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers['location'];
        await response.stream.listen((_) {}, onError: (Object _) {}).cancel();
        if (location == null) {
          throw const HttpException('Reindirizzamento non valido');
        }
        uri = uri.resolve(location);
        continue;
      }
      if (!accepted.contains(response.statusCode)) {
        await response.stream.listen((_) {}, onError: (Object _) {}).cancel();
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
    if (await target.exists()) {
      if (await target.length() == update.size &&
          await _fileDigest(target.path) == update.sha256) {
        return target;
      }
      await target.delete(); // Invalid updater cache, never installed app data.
    }
    final partial = File('${target.path}.part');
    var offset = await partial.exists() ? await partial.length() : 0;
    if (offset == update.size &&
        await _fileDigest(partial.path) == update.sha256) {
      return partial.rename(target.path);
    }
    if (offset >= update.size) {
      await partial.delete();
      offset = 0;
    }
    RandomAccessFile? output;
    var discard = false;
    try {
      final response = await _get(
        update.url,
        headers: {if (offset > 0) 'Range': 'bytes=$offset-'},
        accepted: const {200, 206},
      );
      if (response.statusCode == 206) {
        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
            .firstMatch(response.headers['content-range'] ?? '');
        if (range == null ||
            int.parse(range[1]!) != offset ||
            int.parse(range[2]!) != update.size - 1 ||
            int.parse(range[3]!) != update.size) {
          await response.stream.listen((_) {}, onError: (Object _) {}).cancel();
          throw const FormatException('Intervallo aggiornamento non valido');
        }
      } else {
        offset = 0;
      } // Server ignored Range: replace, never append.
      if (response.contentLength != null &&
          response.contentLength != update.size - offset) {
        await response.stream.listen((_) {}, onError: (Object _) {}).cancel();
        throw const FormatException('Dimensione aggiornamento errata');
      }
      output = await partial.open(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      var received = offset;
      final repaint = Stopwatch()..start();
      var lastRepaint = -100;
      progress(received, update.size);
      await for (final bytes in response.stream.timeout(
        const Duration(seconds: 45),
      )) {
        if (_closed) throw const HttpException('Download annullato');
        if (received + bytes.length > update.size) {
          throw const FormatException('Dimensione aggiornamento errata');
        }
        await output.writeFrom(bytes);
        received += bytes.length;
        if (received == update.size ||
            repaint.elapsedMilliseconds - lastRepaint >= 100) {
          lastRepaint = repaint.elapsedMilliseconds;
          progress(received, update.size);
        }
      }
      await output.flush();
      await output.close();
      output = null;
      if (received != update.size) {
        throw const HttpException('Download interrotto');
      }
      if (await _fileDigest(partial.path) != update.sha256) {
        throw const FormatException('Verifica aggiornamento non riuscita');
      }
      return await partial.rename(target.path);
    } on FormatException {
      discard = true;
      rethrow;
    } finally {
      try {
        await output?.close();
      } finally {
        // A transport interruption retains the prefix for an explicit retry.
        // Invalid metadata/checksums must never be resumed or installed.
        if (discard && await partial.exists()) await partial.delete();
      }
    }
  }

  Future<bool> install(AppUpdate update, File file) async {
    if (await file.length() != update.size ||
        await _fileDigest(file.path) != update.sha256) {
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
      final install = p.dirname(
        await File(Platform.resolvedExecutable).resolveSymbolicLinks(),
      );
      final id =
          '${update.build}-${DateTime.now().microsecondsSinceEpoch}-$pid';
      final script = File(p.join(file.parent.path, 'windows-update-$id.ps1'));
      await script.writeAsString(
        await rootBundle.loadString('assets/update/windows-update.ps1'),
        flush: true,
      );
      final job = File(p.join(file.parent.path, 'job-$id.json'));
      await job.writeAsString(
        jsonEncode({
          'pid': pid,
          'archive': file.path,
          'sha256': update.sha256,
          'install': install,
          'build': update.build,
          'version': update.version,
          'source': update.source,
        }),
        flush: true,
      );
      // Check write access without overwriting an existing user file.
      final probe = await Directory(install)
          .createTemp('.kmreader-update-check-');
      try {
        await File(p.join(probe.path, 'write')).writeAsString('');
      } finally {
        await probe.delete(recursive: true);
      }
      await prepareWindowsUpdate(script, job);
      if (_closed) {
        _windowsInstallStarted = false;
        return false;
      }
      _windowsJob = job;
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
              RegExp(r'job-[0-9]+(?:-[0-9]+-[0-9]+)?\.json\.result$')
                  .hasMatch(f.path),
        )
        .cast<File>()
        .toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (files.isEmpty || await files.first.length() > 65536) return false;
    try {
      final result = jsonDecode(
        (await files.first.readAsString()).replaceFirst('\uFEFF', ''),
      );
      if (result is! Map || result['build'] is! int) return false;
      return switch (result['state']) {
        'failed' => result['build'] > appBuildNumber,
        'restart_failed' => result['build'] >= appBuildNumber,
        _ => false,
      };
    } catch (_) {
      return false;
    }
  }

  Future<void> requestRestart() async {
    final job = _windowsJob;
    if (job != null) {
      _windowsJob = null;
      try {
        await commitWindowsUpdate(job);
      } catch (_) {
        _windowsInstallStarted = false;
        rethrow;
      }
    }
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
