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
  const KomgaUploadPage({
    super.key,
    required this.repository,
    this.initialLibrary,
  });
  final Repository repository;
  final String? initialLibrary;

  @override
  State<KomgaUploadPage> createState() => _State();
}

class _Upload {
  _Upload({
    this.file,
    required this.name,
    this.size,
    this.operation,
    this.receipt,
  });
  XFile? file;
  String name;
  int? size;
  Json? operation, receipt;
  String? error;
  double? progress;
  bool canRename = false;

  bool get uploaded => receipt?['status'] == 'uploaded';
  bool get scanned => receipt?['scan_requested'] == true;
  Json get journal => {'operation': operation, 'receipt': ?receipt};
}

class _State extends State<KomgaUploadPage> {
  late final admin = KomgaLibraryAdmin(widget.repository);
  String get journalKey => 'komgaUpload:${widget.repository.profile.id}';
  final _manualFolder = TextEditingController();
  final _queue = <_Upload>[];
  List<Json> _libraries = [];
  List<String> _folders = [];
  Json _capabilities = {};
  String? _library, _folderNext, _message;
  String _folder = '';
  int _maxBytes = 0, _folderRevision = 0;
  bool _busy = false, _loadingFolders = false, _configured = false;
  Completer<void>? _cancel;

  bool get _hasBrowser => _capabilities['folders'] == true;
  bool get _batchScan => _capabilities['batch_scan'] == true;
  String get _destination => _hasBrowser ? _folder : _manualFolder.text.trim();

  @override
  void initState() {
    super.initState();
    final saved = widget.repository.store.setting<dynamic>(journalKey);
    final values = saved is List
        ? saved.map(object)
        : saved is Map
        ? [
            {'operation': object(saved)},
          ]
        : <Json>[];
    for (final row in values) {
      final operation = object(row['operation']);
      if (text(operation['id']).isEmpty) continue;
      _queue.add(
        _Upload(
          name: text(operation['filename']),
          size: integer(operation['size']),
          operation: operation,
          receipt: object(row['receipt']),
        ),
      );
    }
    _library =
        widget.initialLibrary ??
        text(_queue.firstOrNull?.operation?['library']);
    final previous = _queue.firstOrNull?.operation;
    if (previous?['library'] == _library) {
      _folder = text(previous?['folder']);
      _manualFolder.text = _folder;
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_cancel?.isCompleted == false) _cancel!.complete();
    _manualFolder.dispose();
    super.dispose();
  }

  void _persist() => widget.repository.store.setSetting(journalKey, [
    for (final row in _queue)
      if (row.operation != null) row.journal,
  ]);

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final dto = await admin.uploadLibraries();
      if (!mounted) return;
      _libraries = (dto['libraries'] as List).map(object).toList();
      _capabilities = object(dto['capabilities']);
      _maxBytes = integer(dto['max_upload_bytes']);
      _configured = true;
      _message = null;
      if (!_libraries.any((entry) => entry['id'] == _library)) {
        if (widget.initialLibrary != null) {
          _message = 'This library is unavailable for uploads.';
          _library = null;
        } else {
          _library = _libraries.firstOrNull?['id'] as String?;
        }
        _folder = '';
        _manualFolder.clear();
      }
      if (_hasBrowser) await _loadFolders();
      for (final row in _queue.where(
        (row) => row.operation != null && !row.uploaded,
      )) {
        if (!mounted) break;
        await _status(row);
      }
    } catch (error) {
      if (mounted) {
        _message = error is ApiFailure && error.status == 404
            ? 'Remote upload is not configured on this server.'
            : '$error';
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadFolders({bool more = false}) async {
    final library = _library;
    if (library == null || library.isEmpty) return;
    final request = ++_folderRevision, parent = _folder;
    setState(() {
      _loadingFolders = true;
      if (!more) _folders = [];
    });
    try {
      final page = await admin.folders(
        library,
        parent,
        after: more ? _folderNext : null,
      );
      if (!mounted || request != _folderRevision) return;
      _folders.addAll((page['folders'] as List).cast<String>());
      _folderNext = page['next'] as String?;
    } catch (error) {
      if (mounted && request == _folderRevision) _message = '$error';
    } finally {
      if (mounted && request == _folderRevision) {
        setState(() => _loadingFolders = false);
      }
    }
  }

  Future<void> _openFolder(String path) async {
    _folder = path;
    _message = null;
    await _loadFolders();
  }

  Future<void> _createFolder() async {
    final library = _library;
    if (library == null || library.isEmpty) return;
    final result = await _nameDialog('New folder', '');
    if (!mounted || result == null) return;
    try {
      KomgaLibraryAdmin.validateComponent(result);
      final parent = _folder;
      setState(() => _busy = true);
      final dto = await admin.createFolder(library, parent, result);
      if (!mounted) return;
      final created = text(dto['folder']);
      if (created != (parent.isEmpty ? result : '$parent/$result')) {
        throw const ApiFailure('The server returned an unexpected response.');
      }
      await _openFolder(created);
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick({_Upload? original}) async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Books and comics',
          extensions: ['cbz', 'cbr', 'epub', 'pdf'],
        ),
      ],
    );
    if (files.isEmpty || !mounted) return;
    try {
      if (original != null) {
        // A restored row is matched using its digest before any retransmission.
        if (files.length != 1) {
          throw const ApiFailure(
            'Select the original file to retry this upload.',
          );
        }
        setState(() => original.file = files.single);
        return;
      }
      final rows = <_Upload>[];
      for (final file in files) {
        rows.add(
          _Upload(file: file, name: file.name, size: await file.length()),
        );
      }
      if (mounted) setState(() => _queue.addAll(rows));
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<String?> _nameDialog(String title, String initial) {
    var name = initial;
    return showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(tr(dialog, title)),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          onChanged: (v) => name = v,
          onFieldSubmitted: (v) => Navigator.pop(dialog, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(tr(dialog, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, name.trim()),
            child: Text(tr(dialog, 'Save')),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(_Upload row) async {
    final name = await _nameDialog('Filename', row.name);
    if (!mounted || name == null || name == row.name) return;
    try {
      KomgaLibraryAdmin.validateDestination('series', name);
      setState(() {
        final previous = row.operation;
        if (previous != null && row.canRename) {
          row.operation = {...previous, 'id': _newId(), 'filename': name};
          row.receipt = null;
        }
        row.name = name;
        row.error = null;
        row.canRename = false;
      });
      _persist();
    } catch (error) {
      showError(context, error);
    }
  }

  static String _newId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _status(_Upload row) async {
    try {
      final receipt = await admin.uploadStatus(text(row.operation?['id']));
      if (!mounted) return;
      setState(() {
        row.receipt = receipt;
        row.error = null;
      });
      _persist();
    } on ApiFailure catch (error) {
      if (!mounted) return;
      if (error.status != 404) rethrow;
      setState(
        () => row.error = 'The server has not recorded this upload. You can retry with the same file.',
      );
    }
  }

  Future<void> _upload(
    _Upload row,
    String library,
    String folder,
    Completer<void> cancel,
  ) async {
    final file = row.file!;
    final size = await file.length();
    final operation = row.operation;
    final name = row.name.trim();
    if (size <= 0 || size > _maxBytes) {
      throw const ApiFailure('File exceeds the configured upload limit');
    }
    KomgaLibraryAdmin.validateDestination(
      text(operation?['folder'], folder),
      name,
    );
    if (operation != null) {
      await _status(row);
      if (row.uploaded || !mounted || cancel.isCompleted) return;
    }
    final digest = await KomgaLibraryAdmin.digest(file);
    if (!mounted || cancel.isCompleted) return;
    if (operation != null &&
        (operation['sha256'] != digest || operation['size'] != size)) {
      throw const ApiFailure('Select the original file to retry this upload.');
    }
    row.operation ??= {
      'id': _newId(),
      'library': library,
      'folder': folder,
      'filename': name,
      'size': size,
      'sha256': digest,
      'deferScan': _batchScan,
    };
    _persist();
    final clock = Stopwatch()..start();
    var update = -100;
    final receipt = await admin.upload(file, row.operation!, (sent) {
      if (mounted &&
          (sent == size || clock.elapsedMilliseconds - update >= 100)) {
        update = clock.elapsedMilliseconds;
        setState(() => row.progress = sent / size);
      }
    }, cancel.future);
    if (!mounted) return;
    setState(() {
      row.receipt = receipt;
      row.error = null;
      row.progress = null;
    });
    _persist();
  }

  bool get _canSend => _queue.any(
    (row) =>
        row.file != null &&
        !row.uploaded &&
        (row.operation != null ||
            (text(_library).isNotEmpty && _destination.isNotEmpty)),
  );

  Future<void> _send() async {
    if (_busy || !_canSend) return;
    final library = text(_library), folder = _destination;
    final cancel = Completer<void>();
    setState(() {
      _cancel = cancel;
      _busy = true;
      _message = null;
    });
    try {
      for (final row in _queue.where(
        (row) => row.file != null && !row.uploaded,
      )) {
        if (!mounted || cancel.isCompleted) break;
        if (row.operation == null && (library.isEmpty || folder.isEmpty)) {
          continue;
        }
        setState(() {
          row.error = null;
          row.progress = 0;
        });
        try {
          await _upload(row, library, folder, cancel);
        } catch (error) {
          if (!mounted) return;
          setState(() {
            row.error = '$error';
            row.canRename =
                error is ApiFailure &&
                error.status == 409 &&
                error.message.contains('file with this name');
          });
        } finally {
          if (mounted) setState(() => row.progress = null);
        }
      }
      if (mounted && !cancel.isCompleted) await _scanCompleted();
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _cancel = null;
        });
      }
    }
  }

  Future<void> _scanCompleted() async {
    final groups = <String, List<_Upload>>{};
    for (final row in _queue.where((row) => row.uploaded && !row.scanned)) {
      (groups[text(row.operation?['library'])] ??= []).add(row);
    }
    for (final entry in groups.entries) {
      if (_batchScan) {
        for (var start = 0; start < entry.value.length; start += 100) {
          final batch = entry.value.skip(start).take(100);
          await admin.scanBatch(entry.key, [
            for (final row in batch) text(row.operation?['id']),
          ]);
          for (final row in batch) {
            row.receipt = {...object(row.receipt), 'scan_requested': true};
          }
          _persist();
        }
      } else {
        for (final row in entry.value) {
          row.receipt = await admin.scanUpload(text(row.operation?['id']));
          _persist();
        }
      }
    }
    if (groups.isNotEmpty || _queue.any((row) => row.uploaded)) {
      widget.repository.refreshContent();
    }
  }

  Future<void> _action(Future<void> Function() run) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await run();
    } catch (error) {
      if (mounted) _message = '$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _size(int size) => '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';

  Widget _destinationCard() {
    final parts = _folder.isEmpty ? <String>[] : _folder.split('/');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr(context, 'Destination'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey(_library),
              initialValue: _libraries.any((l) => l['id'] == _library)
                  ? _library
                  : null,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr(context, 'Library')),
              items: [
                for (final entry in _libraries)
                  DropdownMenuItem(
                    value: text(entry['id']),
                    child: Text(
                      text(entry['name']),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      setState(() {
                        _library = value;
                        _folder = '';
                        _manualFolder.clear();
                      });
                      if (_hasBrowser) unawaited(_loadFolders());
                    },
            ),
            const SizedBox(height: 12),
            if (_hasBrowser) ...[
              Wrap(
                spacing: 6,
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => _openFolder(''),
                    child: Text(tr(context, 'Library root')),
                  ),
                  for (var i = 0; i < parts.length; i++)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _openFolder(parts.take(i + 1).join('/')),
                      child: Text(parts[i]),
                    ),
                ],
              ),
              if (_loadingFolders) const LinearProgressIndicator(),
              if (!_loadingFolders && _folders.isEmpty)
                Text(tr(context, 'No subfolders')),
              for (final folder in _folders)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(folder),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy
                      ? null
                      : () => _openFolder([...parts, folder].join('/')),
                ),
              if (_folderNext != null)
                TextButton(
                  onPressed: _busy || _loadingFolders
                      ? null
                      : () => _loadFolders(more: true),
                  child: Text(tr(context, 'Load more')),
                ),
              OutlinedButton.icon(
                icon: const Icon(Icons.create_new_folder_outlined),
                label: Text(tr(context, 'New folder')),
                onPressed: _busy || text(_library).isEmpty
                    ? null
                    : _createFolder,
              ),
            ] else
              TextField(
                controller: _manualFolder,
                enabled: !_busy,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: tr(context, 'Series folder'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _queueCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr(context, 'Files to upload'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (_maxBytes > 0)
            Text('${tr(context, 'Maximum per file')} · ${_size(_maxBytes)}'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pick,
            icon: const Icon(Icons.upload_file),
            label: Text(tr(context, 'Choose files')),
          ),
          for (final row in _queue) ...[
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                row.uploaded
                    ? Icons.check_circle_outline
                    : Icons.description_outlined,
              ),
              title: Text(row.name),
              subtitle: Text(
                [
                  if (row.size != null) _size(row.size!),
                  if (row.operation != null) text(row.operation?['folder']),
                  if (row.uploaded)
                    tr(
                      context,
                      row.scanned ? 'Scan requested' : 'File uploaded',
                    ),
                  if (row.error != null) tr(context, row.error!),
                ].join(' · '),
              ),
              trailing: PopupMenuButton<String>(
                enabled: !_busy,
                onSelected: (action) async {
                  if (action == 'rename') await _rename(row);
                  if (action == 'pick') await _pick(original: row);
                  if (action == 'status') await _action(() => _status(row));
                  if (action == 'remove' && mounted) {
                    setState(() => _queue.remove(row));
                    _persist();
                  }
                },
                itemBuilder: (_) => [
                  if (row.operation == null || row.canRename)
                    PopupMenuItem(
                      value: 'rename',
                      child: Text(tr(context, 'Filename')),
                    ),
                  if (!row.uploaded && row.operation != null)
                    PopupMenuItem(
                      value: 'pick',
                      child: Text(tr(context, 'Select original file')),
                    ),
                  if (!row.uploaded && row.operation != null)
                    PopupMenuItem(
                      value: 'status',
                      child: Text(tr(context, 'Check upload status')),
                    ),
                  if (row.operation == null || row.scanned)
                    PopupMenuItem(
                      value: 'remove',
                      child: Text(tr(context, 'Remove from queue')),
                    ),
                ],
              ),
            ),
            if (row.progress != null)
              LinearProgressIndicator(value: row.progress),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy || !_canSend ? null : _send,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(tr(context, 'Upload to Komga')),
          ),
          if (_cancel?.isCompleted == false)
            TextButton(
              onPressed: () => setState(() => _cancel!.complete()),
              child: Text(tr(context, 'Cancel upload')),
            ),
          if (_queue.any((row) => row.uploaded && !row.scanned))
            TextButton(
              onPressed: _busy ? null : () => _action(_scanCompleted),
              child: Text(tr(context, 'Scan library')),
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'Add to Komga'))),
    body: LayoutBuilder(
      builder: (context, box) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1130),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_busy && _cancel == null) const LinearProgressIndicator(),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(tr(context, _message!)),
                ),
              if (!_configured) ...[
                FilledButton(
                  onPressed: _busy ? null : _load,
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
              ] else if (box.maxWidth >= 800)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _destinationCard()),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: _queueCard()),
                  ],
                )
              else ...[
                _destinationCard(),
                _queueCard(),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
