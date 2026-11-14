import 'dart:async';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/komga_library_admin.dart';
import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';

class KomgaUploadPage extends StatefulWidget {
  const KomgaUploadPage({super.key, required this.repository});
  final Repository repository;
  @override
  State<KomgaUploadPage> createState() => _State();
}

class _State extends State<KomgaUploadPage> {
  late final admin = KomgaLibraryAdmin(widget.repository);
  String get journalKey => 'komgaUpload:${widget.repository.profile.id}';
  final folder = TextEditingController();
  final filename = TextEditingController();
  List<Json> libraries = [];
  String? library, message;
  XFile? file;
  Json? operation, receipt;
  bool busy = false, configured = false;
  int maximum = 0;
  double? progress;
  Completer<void>? cancel;
  @override
  void initState() {
    super.initState();
    final saved = widget.repository.store.setting<dynamic>(journalKey);
    if (saved is Map) {
      operation = object(saved);
      library = text(operation!['library']);
      folder.text = text(operation!['folder']);
      filename.text = text(operation!['filename']);
    }
    load();
  }

  @override
  void dispose() {
    if (cancel?.isCompleted == false) cancel!.complete();
    folder.dispose();
    filename.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() => busy = true);
    try {
      final dto = await admin.uploadLibraries();
      if (!mounted) return;
      setState(() {
        libraries = (dto['libraries'] as List).map(object).toList();
        configured = true;
        maximum = integer(dto['max_upload_bytes']);
        if (!libraries.any((entry) => entry['id'] == library)) library = null;
        message = null;
      });
      if (operation != null) await status();
    } catch (error) {
      if (mounted) {
        setState(
          () => message = error is ApiFailure && error.status == 404
              ? tr(context, 'Remote upload is not configured on this server.')
              : '$error',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> status() async {
    final current = operation;
    if (current == null) return;
    try {
      final value = await admin.uploadStatus(text(current['id']));
      if (!mounted) return;
      setState(() {
        receipt = value;
        message = null;
      });
      widget.repository.refreshContent();
    } catch (error) {
      if (mounted) {
        setState(
          () => message = error is ApiFailure && error.status == 404
              ? tr(
                  context,
                  'The server has not recorded this upload. You can retry with the same file.',
                )
              : '$error',
        );
      }
    }
  }

  Future<void> select() async {
    final selected = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Books and comics',
          extensions: ['cbz', 'cbr', 'epub', 'pdf'],
        ),
      ],
    );
    if (selected == null || !mounted) return;
    setState(() {
      file = selected;
      if (operation == null) filename.text = selected.name;
    });
  }

  static String newId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> send() async {
    final selected = file;
    if (selected == null || library == null || busy) return;
    setState(() {
      busy = true;
      message = null;
      progress = null;
    });
    cancel = Completer<void>();
    try {
      final size = await selected.length();
      if (size <= 0 ||
          size > maximum ||
          folder.text.trim().isEmpty ||
          filename.text.trim().isEmpty) {
        throw const ApiFailure(
          'Choose a file within the server limit and enter a series folder and filename.',
        );
      }
      KomgaLibraryAdmin.validateDestination(
        folder.text.trim(),
        filename.text.trim(),
      );
      final digest = await KomgaLibraryAdmin.digest(selected);
      if (!mounted || cancel!.isCompleted) return;
      if (operation != null) {
        if (operation!['sha256'] != digest || operation!['size'] != size) {
          throw const ApiFailure(
            'Select the original file to retry this upload.',
          );
        }
        try {
          final previous = await admin.uploadStatus(text(operation!['id']));
          if (previous['status'] == 'uploaded') {
            if (mounted) setState(() => receipt = previous);
            return;
          }
        } on ApiFailure catch (error) {
          if (error.status != 404) rethrow;
        }
      } else {
        operation = {
          'id': newId(),
          'library': library,
          'folder': folder.text.trim(),
          'filename': filename.text.trim(),
          'size': size,
          'sha256': digest,
        };
        widget.repository.store.setSetting(journalKey, operation);
      }
      final value = await admin.upload(selected, operation!, (sent) {
        if (mounted) setState(() => progress = sent / size);
      }, cancel!.future);
      if (mounted) {
        setState(() {
          receipt = value;
          progress = 1;
        });
      }
      widget.repository.refreshContent();
    } catch (error) {
      if (mounted) setState(() => message = '$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> scan() async {
    if (operation == null) return;
    setState(() => busy = true);
    try {
      final value = await admin.scanUpload(text(operation!['id']));
      if (mounted) setState(() => receipt = value);
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'Add to Komga'))),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          tr(
            context,
            'Upload a new EPUB, PDF, CBZ or CBR to your Komga library. Existing files are never replaced.',
          ),
        ),
        const SizedBox(height: 16),
        if (!configured) ...[
          FilledButton(
            onPressed: busy ? null : load,
            child: Text(tr(context, 'Retry')),
          ),
          TextButton(
            onPressed: () => launchUrl(
              Uri.parse(
                'https://github.com/LeValue/KMReader-Porting/blob/main/docs/KOMGA_LIBRARY_MANAGEMENT.md',
              ),
              mode: LaunchMode.externalApplication,
            ),
            child: Text(tr(context, 'Server setup instructions')),
          ),
        ],
        if (configured) ...[
          DropdownButtonFormField<String>(
            initialValue: libraries.any((l) => l['id'] == library)
                ? library
                : null,
            decoration: InputDecoration(labelText: tr(context, 'Library')),
            items: [
              for (final entry in libraries)
                DropdownMenuItem(
                  value: text(entry['id']),
                  child: Text(text(entry['name'])),
                ),
            ],
            onChanged: busy || operation != null
                ? null
                : (value) => setState(() => library = value),
          ),
          TextField(
            controller: folder,
            enabled: !busy && operation == null,
            decoration: InputDecoration(
              labelText: tr(context, 'Series folder'),
              hintText: tr(context, 'Example: Marvel/X-Men'),
            ),
          ),
          TextField(
            controller: filename,
            enabled: !busy && operation == null,
            decoration: InputDecoration(labelText: tr(context, 'Filename')),
          ),
          OutlinedButton.icon(
            onPressed: busy ? null : select,
            icon: const Icon(Icons.upload_file),
            label: Text(file?.name ?? tr(context, 'Choose file')),
          ),
          if (maximum > 0)
            Text(
              '${(maximum / 1024 / 1024).floor()} MB ${tr(context, 'maximum')}',
            ),
          if (receipt?['status'] != 'uploaded')
            FilledButton(
              onPressed: busy || file == null || library == null ? null : send,
              child: Text(
                tr(
                  context,
                  operation == null ? 'Upload to Komga' : 'Retry upload',
                ),
              ),
            ),
          if (operation != null)
            OutlinedButton(
              onPressed: busy ? null : status,
              child: Text(tr(context, 'Check upload status')),
            ),
          if (receipt != null && receipt?['status'] != 'uploaded')
            Text(
              tr(
                context,
                'Upload not confirmed. Retry with the original file to recover its result.',
              ),
            ),
          if (receipt?['status'] == 'uploaded') ...[
            Text(
              tr(
                context,
                receipt?['scan_requested'] == true
                    ? 'File uploaded. Komga is scanning the library; new content may take a moment to appear.'
                    : 'File uploaded. Request a scan to add it to the catalog.',
              ),
            ),
            if (receipt?['scan_requested'] != true)
              FilledButton(
                onPressed: busy ? null : scan,
                child: Text(tr(context, 'Scan library')),
              ),
          ],
          if (operation != null)
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (receipt?['status'] != 'uploaded' &&
                          !await confirm(
                            context,
                            'New upload',
                            'The previous upload may still be running. Check its status before starting another file.',
                          )) {
                        return;
                      }
                      widget.repository.store.setSetting(journalKey, null);
                      if (mounted) {
                        setState(() {
                          operation = null;
                          receipt = null;
                          file = null;
                          message = null;
                          filename.clear();
                        });
                      }
                    },
              child: Text(tr(context, 'New upload')),
            ),
        ],
        if (busy) LinearProgressIndicator(value: progress),
        if (busy && cancel != null && !cancel!.isCompleted)
          TextButton(
            onPressed: () {
              if (!cancel!.isCompleted) {
                setState(() => cancel!.complete());
              }
            },
            child: Text(tr(context, 'Cancel upload')),
          ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(tr(context, message!)),
          ),
      ],
    ),
  );
}
