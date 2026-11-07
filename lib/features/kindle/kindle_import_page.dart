import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../core/kindle/client.dart';
import '../../core/kindle/import.dart';
import '../../core/kindle/repository.dart';
import '../../ui/strings.dart';

class KindleImportPage extends StatefulWidget {
  const KindleImportPage({super.key, required this.repository});
  final KindleRepository repository;
  @override
  State<KindleImportPage> createState() => _KindleImportPageState();
}

class _KindleImportPageState extends State<KindleImportPage> {
  late final _importer = KindleImporter(widget.repository.library.client);
  final _title = TextEditingController(), _author = TextEditingController();
  var _cancel = KindleImportCancellation();
  List<KindleImportDevice>? _devices;
  final _targets = <String>{};
  XFile? _file;
  bool _loading = true, _busy = false, _submitting = false;
  bool _accepted = false, _uncertain = false;
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  @override
  void dispose() {
    _cancel.cancel();
    _title.dispose();
    _author.dispose();
    super.dispose();
  }

  String _message(Object error) {
    final key = error is KindleFailure
        ? switch (error.code) {
            'import_format' =>
              'This file format is not supported by Send to Kindle.',
            'import_size' => 'Choose a non-empty file up to 200 MB.',
            'import_metadata' =>
              'Enter a title and select at least one Kindle device.',
            'import_cancelled' => 'Upload cancelled before delivery.',
            'import_delivery_uncertain' => 'Amazon did not confirm delivery. Check your Kindle library before sending this file again.',
            'import_rejected' => 'Amazon rejected the request. Check your connection and Kindle account, or use the Amazon website.',
            _ => 'Kindle upload unavailable. Check your connection and account, or use the Amazon website.',
          }
        : 'Kindle upload unavailable. Check your connection and account, or use the Amazon website.';
    return tr(context, key);
  }

  Future<void> _loadDevices() async {
    _cancel = KindleImportCancellation();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final devices = await _importer.devices(_cancel);
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _targets.clear();
      });
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
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
        _title.text = p.basenameWithoutExtension(file.name);
        _error = null;
        _accepted = false;
        _progress = 0;
      });
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
    try {
      await _importer.upload(
        file,
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
      if (!mounted) return;
      setState(() => _accepted = true);
      widget.repository.refreshContent();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _message(error);
          _uncertain =
              error is KindleFailure &&
              error.code == 'import_delivery_uncertain';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Send to Kindle'))),
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
                  'Choose a file from this device. Amazon will add it to this account’s Kindle library and deliver it to the selected devices.',
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
              const SizedBox(height: 12),
              Text(
                tr(context, 'Deliver to'),
                style: Theme.of(context).textTheme.titleMedium,
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
                    'No compatible Kindle devices found. Use the Amazon website to add documents to your library.',
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
                      'Accepted by Amazon. Processing can take a few minutes; refresh your library later.',
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed:
                    _busy ||
                        _loading ||
                        _file == null ||
                        _targets.isEmpty ||
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
