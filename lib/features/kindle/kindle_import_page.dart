import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../core/kindle/client.dart';
import '../../core/kindle/import.dart';
import '../../core/kindle/management.dart';
import '../../core/kindle/document_edit.dart';
import '../../core/models.dart';
import '../../core/kindle/repository.dart';
import '../../ui/strings.dart';
import 'kindle_send_login_page.dart';

class KindleImportPage extends StatefulWidget {
  const KindleImportPage({super.key, required this.repository, this.replacing});
  final KindleRepository repository;
  final Book? replacing;
  @override
  State<KindleImportPage> createState() => _KindleImportPageState();
}

class _KindleImportPageState extends State<KindleImportPage> {
  late final _importer = KindleImporter(widget.repository.library.client);
  final _title = TextEditingController(), _author = TextEditingController();
  final _summary = TextEditingController(), _language = TextEditingController();
  var _cancel = KindleImportCancellation();
  var _deviceCancel = KindleImportCancellation();
  List<KindleImportDevice>? _devices;
  final _targets = <String>{};
  XFile? _file, _cover;
  bool _archive = true, _loading = false, _busy = false, _submitting = false;
  bool _accepted = false, _uncertain = false;
  bool _authorizationNeeded = false;
  double _progress = 0;
  String? _error, _deviceError;

  @override
  void initState() {
    super.initState();
    if (widget.replacing case final book?) {
      _title.text = book.title;
      _summary.text = text(book.metadata['summary']);
      _language.text = text(book.metadata['language']);
      _author.text = (book.metadata['authors'] as List? ?? [])
          .map((a) => object(a)['name'])
          .whereType<String>()
          .join(', ');
    }
  }

  @override
  void dispose() {
    _cancel.cancel();
    _deviceCancel.cancel();
    _title.dispose();
    _author.dispose();
    _summary.dispose();
    _language.dispose();
    super.dispose();
  }

  String _message(Object error) {
    final key = error is KindleFailure
        ? switch (error.code) {
            'management_cover_layout' => 'This EPUB uses a cover format that cannot be replaced safely. Use an EPUB with a JPG or PNG cover.',
            'management_cover' =>
              'Choose a valid JPG or PNG cover up to 20 MB.',
            'management_pending' => 'An operation is already pending for this document. Check its status before trying again.',
            'management_busy' => 'Finish pending downloads and reading synchronization before changing this document.',
            'management_offline' =>
              'Connect this Kindle account before changing its cloud library.',
            'management_epub_required' =>
              'Cover editing requires an EPUB file.',
            'import_format' =>
              'This file format is not supported by Send to Kindle.',
            'import_size' => 'Choose a non-empty file up to 200 MB.',
            'import_metadata' => 'Enter a title up to 250 characters.',
            'import_targets' => 'Select at least one Kindle device.',
            'import_cancelled' => 'Upload cancelled before delivery.',
            'import_delivery_uncertain' => 'Amazon did not confirm delivery. Check your Kindle library before sending this file again.',
            'import_rejected' => 'Amazon rejected the request. Check your connection and Kindle account, or use the Amazon website.',
            _ => 'Kindle upload unavailable. Check your connection and account, or use the Amazon website.',
          }
        : 'Kindle upload unavailable. Check your connection and account, or use the Amazon website.';
    final diagnostic = error is KindleFailure ? '\n${error.toString()}' : '';
    return '${tr(context, key)}$diagnostic';
  }

  Future<void> _loadDevices() async {
    if (_loading) return;
    _deviceCancel = KindleImportCancellation();
    setState(() {
      _loading = true;
      _deviceError = null;
      _authorizationNeeded = false;
    });
    try {
      final devices = await _importer.devices(_deviceCancel);
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _targets.clear();
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _deviceError = _message(error);
          _authorizationNeeded =
              error is KindleFailure &&
              error.stage == 'registration' &&
              (error.status == 401 || error.status == 403);
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pick() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Send to Kindle',
            extensions: kindleImportExtensions,
          ),
        ],
      );
      if (!mounted || file == null) return;
      final length = await file.length();
      if (length <= 0 || length > kindleImportMaxBytes) {
        throw const KindleFailure('import_size');
      }
      if (!mounted) return;
      setState(() {
        _file = file;
        if (p.extension(file.name).toLowerCase() != '.epub') _cover = null;
        if (widget.replacing == null) {
          _title.text = p.basenameWithoutExtension(file.name);
        }
        _error = null;
        _accepted = false;
        _progress = 0;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  Future<void> _pickCover() async {
    try {
      final cover = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Cover', extensions: ['jpg', 'jpeg', 'png']),
        ],
      );
      if (cover == null) return;
      if (await cover.length() > 20 * 1024 * 1024) {
        throw const KindleFailure('management_cover');
      }
      if (mounted) setState(() => _cover = cover);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  Future<void> _send() async {
    final file = _file;
    if (file == null || _busy || _accepted || _uncertain) return;
    _cancel = KindleImportCancellation();
    setState(() {
      _busy = true;
      _submitting = false;
      _error = null;
      _progress = 0;
    });
    Directory? temporary;
    try {
      var prepared = file;
      if (p.extension(file.name).toLowerCase() == '.epub') {
        final root = Directory(
          p.join(
            widget.repository.directory.path,
            widget.repository.profile.id,
            'kindle-edits',
          ),
        );
        await root.create(recursive: true);
        temporary = await root.createTemp('edit-');
        final source = p.join(temporary.path, 'source.epub');
        await file.saveTo(source);
        String? cover;
        if (_cover != null) {
          cover = p.join(temporary.path, 'cover');
          await _cover!.saveTo(cover);
        }
        final target = p.join(temporary.path, 'updated.epub');
        await editKindleEpub(
          source: source,
          target: target,
          title: _title.text,
          author: _author.text,
          cover: cover,
          summary: widget.replacing != null ? _summary.text : null,
          language: widget.replacing != null ? _language.text.trim() : null,
        );
        prepared = XFile(target);
      } else if (_cover != null) {
        throw const KindleFailure('management_epub_required');
      }
      if (widget.replacing case final book?) {
        await KindleDocumentManager(widget.repository).sendUpdatedVersion(
          book,
          prepared,
          title: _title.text,
          author: _author.text,
          targets: _targets.toList(),
          cancel: _cancel,
          onProgress: (sent, total) {
            if (mounted) setState(() => _progress = sent / total);
          },
          onSubmitting: () {
            if (mounted) setState(() => _submitting = true);
          },
        );
      } else {
        await _importer.upload(
          prepared,
          title: _title.text,
          author: _author.text,
          targets: _targets.toList(),
          archive: _archive,
          cancel: _cancel,
          onProgress: (sent, total) {
            if (mounted) setState(() => _progress = sent / total);
          },
          onSubmitting: () {
            if (mounted) setState(() => _submitting = true);
          },
        );
      }
      if (!mounted) return;
      setState(() => _accepted = true);
      if (_archive) widget.repository.refreshContent();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _message(error);
          _authorizationNeeded =
              error is KindleFailure &&
              error.stage == 'registration' &&
              (error.status == 401 || error.status == 403);
          _uncertain =
              error is KindleFailure &&
              error.code == 'import_delivery_uncertain';
        });
      }
    } finally {
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete(recursive: true);
        }
      } on FileSystemException {
        // Windows providers can retain a handle after delivery. A cleanup
        // failure must not turn acceptance into a second send or a stuck screen.
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          tr(
            context,
            widget.replacing == null
                ? 'Send to Kindle'
                : 'Update Kindle document',
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                widget.repository.profile.name,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                tr(
                  context,
                  'Choose a file from this device and where to send it.',
                ),
              ),
              if (widget.replacing != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    tr(
                      context,
                      'Amazon receives an updated copy. The original is kept until reading position and bookmarks can be migrated and verified. Automatic replacement is not yet available.',
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'EPUB, PDF, DOC/DOCX, TXT, RTF, HTML, JPG, PNG, GIF, BMP · ${tr(context, 'Up to 200 MB')}',
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: _busy || _uncertain ? null : _pick,
                icon: const Icon(Icons.upload_file),
                label: Text(_file?.name ?? tr(context, 'Choose file')),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                enabled: !_busy && !_accepted && !_uncertain,
                maxLength: 250,
                decoration: InputDecoration(labelText: tr(context, 'Title')),
              ),
              TextField(
                controller: _author,
                enabled: !_busy && !_accepted && !_uncertain,
                maxLength: 250,
                decoration: InputDecoration(labelText: tr(context, 'Author')),
              ),
              if (widget.replacing != null) ...[
                TextField(
                  controller: _language,
                  enabled: !_busy && !_accepted && !_uncertain,
                  decoration: InputDecoration(
                    labelText: tr(context, 'Language'),
                  ),
                ),
                TextField(
                  controller: _summary,
                  enabled: !_busy && !_accepted && !_uncertain,
                  maxLength: 4000,
                  minLines: 2,
                  maxLines: 5,
                  decoration: InputDecoration(
                    labelText: tr(context, 'Summary'),
                  ),
                ),
              ],
              OutlinedButton.icon(
                onPressed:
                    _busy ||
                        _accepted ||
                        _uncertain ||
                        (_file != null &&
                            p.extension(_file!.name).toLowerCase() != '.epub')
                    ? null
                    : _pickCover,
                icon: const Icon(Icons.image),
                label: Text(_cover?.name ?? tr(context, 'Choose cover (EPUB)')),
              ),
              if (_cover != null)
                TextButton(
                  onPressed: _busy ? null : () => setState(() => _cover = null),
                  child: Text(tr(context, 'Remove selected cover')),
                ),
              const SizedBox(height: 12),
              if (widget.replacing == null)
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr(context, 'Add to Kindle library')),
                  subtitle: Text(
                    tr(
                      context,
                      'Available on compatible devices connected to this account.',
                    ),
                  ),
                  value: _archive,
                  onChanged: _busy || _accepted || _uncertain
                      ? null
                      : (value) {
                          setState(() => _archive = value);
                          if (!value && _devices == null && !_loading) {
                            _loadDevices();
                          }
                        },
                ),
              if (!_archive) ...[
                Text(
                  tr(context, 'Send only to selected devices'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  tr(
                    context,
                    'Files sent only to devices are not added to your cloud library and cannot be synced or shared.',
                  ),
                ),
                if (_loading)
                  const LinearProgressIndicator()
                else if (_devices == null)
                  TextButton(
                    onPressed: _loadDevices,
                    child: Text(tr(context, 'Retry')),
                  )
                else if (_devices!.isEmpty)
                  Text(
                    tr(
                      context,
                      'No compatible Kindle devices found. You can still add this file to your Kindle library.',
                    ),
                  )
                else
                  for (final device in _devices!)
                    CheckboxListTile(
                      title: Text(device.name),
                      value: _targets.contains(device.serial),
                      onChanged: _busy || _accepted || _uncertain
                          ? null
                          : (value) => setState(() {
                              if (value == true) {
                                _targets.add(device.serial);
                              } else {
                                _targets.remove(device.serial);
                              }
                            }),
                    ),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _submitting ? null : _progress),
                Text(
                  _submitting
                      ? tr(context, 'Waiting for Amazon confirmation…')
                      : '${(_progress * 100).round()}%',
                ),
                TextButton(
                  onPressed: _cancel.cancel,
                  child: Text(tr(context, 'Cancel')),
                ),
              ],
              if (_authorizationNeeded)
                TextButton.icon(
                  onPressed: _loading || _busy
                      ? null
                      : () async {
                          final connected = await Navigator.of(context)
                              .push<bool>(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      KindleSendLoginPage(importer: _importer),
                                ),
                              );
                          if (mounted && connected == true) {
                            setState(() {
                              _authorizationNeeded = false;
                              _error = null;
                            });
                            if (!_archive) await _loadDevices();
                          }
                        },
                  icon: const Icon(Icons.login),
                  label: Text(tr(context, 'Authorize Send to Kindle')),
                ),
              if (!_archive && _deviceError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: SelectableText(
                    _deviceError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_accepted)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    tr(
                      context,
                      widget.replacing == null
                          ? (_archive
                                ? 'Accepted by Amazon. Processing can take a few minutes; refresh your library later.'
                                : 'Accepted by Amazon for delivery to the selected devices. This file is not added to your cloud library.')
                          : 'Updated copy accepted. The original is preserved; reading position and bookmarks have not been migrated yet.',
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed:
                    _busy ||
                        (!_archive && _loading) ||
                        _file == null ||
                        (!_archive && (_devices == null || _targets.isEmpty)) ||
                        _accepted ||
                        _uncertain
                    ? null
                    : _send,
                icon: const Icon(Icons.send),
                label: Text(tr(context, 'Send to Kindle')),
              ),
              if (_accepted || _uncertain)
                TextButton(
                  onPressed: () {
                    widget.repository.refreshContent();
                    Navigator.pop(context);
                  },
                  child: Text(tr(context, 'Return to library')),
                ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => launchUrl(
                        Uri.parse('https://www.amazon.it/sendtokindle'),
                        mode: LaunchMode.externalApplication,
                      ),
                child: Text(tr(context, 'Open Send to Kindle on Amazon')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
