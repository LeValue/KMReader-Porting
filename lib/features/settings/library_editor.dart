import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';

const libraryFlags = {
  'scanCbx': 'Scan Comic Archives',
  'scanPdf': 'Scan PDF',
  'scanEpub': 'Scan EPUB',
  'scanOnStartup': 'Scan on Startup',
  'scanForceModifiedTime': 'Force Modified Time',
  'emptyTrashAfterScan': 'Empty Trash after Scan',
  'hashFiles': 'Hash Files',
  'hashPages': 'Hash Pages',
  'hashKoreader': 'Hash for KOReader',
  'analyzeDimensions': 'Analyze Page Dimensions',
  'repairExtensions': 'Repair Extensions',
  'convertToCbz': 'Convert to CBZ',
  'importComicInfoBook': 'Import ComicInfo Book Metadata',
  'importComicInfoSeries': 'Import ComicInfo Series Metadata',
  'importComicInfoCollection': 'Import ComicInfo Collections',
  'importComicInfoReadList': 'Import ComicInfo Read Lists',
  'importComicInfoSeriesAppendVolume': 'Append ComicInfo Volume',
  'importEpubBook': 'Import EPUB Book Metadata',
  'importEpubSeries': 'Import EPUB Series Metadata',
  'importMylarSeries': 'Import Mylar Series Metadata',
  'importLocalArtwork': 'Import Local Artwork',
  'importBarcodeIsbn': 'Import Barcode ISBN',
};
Json defaultLibrary() => {
  'name': '',
  'root': '',
  'oneshotsDirectory': '',
  'scanInterval': 'EVERY_6H',
  'seriesCover': 'FIRST',
  'scanDirectoryExclusions': ['#recycle', '@eaDir', '@Recycle'],
  for (final key in libraryFlags.keys)
    key: ![
      'scanOnStartup',
      'scanForceModifiedTime',
      'emptyTrashAfterScan',
      'hashPages',
      'hashKoreader',
      'repairExtensions',
      'convertToCbz',
      'importBarcodeIsbn',
    ].contains(key),
};
Json libraryPatch(Json values, Json? original) {
  final all = <String, dynamic>{};
  for (final key in defaultLibrary().keys) {
    final dynamic value = values[key];
    if (key == 'name' || key == 'root') {
      if (text(value).trim().isEmpty) {
        throw const FormatException('Name and root folder are required.');
      }
      all[key] = text(value).trim();
    } else if (key == 'scanDirectoryExclusions') {
      all[key] = (value as List? ?? [])
          .map((v) => '$v'.trim())
          .where((v) => v.isNotEmpty)
          .toSet()
          .toList();
    } else {
      all[key] = value;
    }
  }
  if (![
        'DISABLED',
        'HOURLY',
        'EVERY_6H',
        'EVERY_12H',
        'DAILY',
        'WEEKLY',
      ].contains(all['scanInterval']) ||
      ![
        'FIRST',
        'FIRST_UNREAD_OR_FIRST',
        'FIRST_UNREAD_OR_LAST',
        'LAST',
      ].contains(all['seriesCover'])) {
    throw const FormatException('Choose valid library settings.');
  }
  return {
    for (final e in all.entries)
      if (original == null ||
          jsonEncode(original[e.key]) != jsonEncode(e.value))
        e.key: e.value,
  };
}

class LibraryEditor extends StatefulWidget {
  const LibraryEditor({super.key, required this.repository, this.library});
  final Repository repository;
  final Json? library;
  @override
  State<LibraryEditor> createState() => _LibraryEditorState();
}

class _LibraryEditorState extends State<LibraryEditor> {
  late Json _values;
  late final Map<String, TextEditingController> _inputs;
  bool _busy = false, _saved = false;
  bool get _dirty =>
      jsonEncode(_values) !=
      jsonEncode({...defaultLibrary(), ...?widget.library});
  @override
  void initState() {
    super.initState();
    _values = {...defaultLibrary(), ...?widget.library};
    _inputs = {
      for (final key in [
        'name',
        'root',
        'oneshotsDirectory',
        'scanDirectoryExclusions',
      ])
        key: TextEditingController(
          text: key == 'scanDirectoryExclusions'
              ? (_values[key] as List).join('\n')
              : text(_values[key]),
        ),
    };
  }

  @override
  void dispose() {
    for (final input in _inputs.values) {
      input.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    try {
      if (!widget.repository.profile.admin) {
        throw const ApiFailure('Admin access required.', status: 403);
      }
      if (widget.repository.offline) {
        throw const ApiFailure(
          'Reconnect to edit server content.',
          offline: true,
        );
      }
      final patch = libraryPatch(_values, widget.library);
      if (patch.isEmpty) {
        Navigator.pop(context);
        return;
      }
      setState(() => _busy = true);
      final id = widget.library?['id'];
      if (id != null) {
        final latest = object(
          await widget.repository.api.request(
            '/api/v1/libraries/${Uri.encodeComponent(id)}',
          ),
        );
        for (final key in patch.keys) {
          if (jsonEncode(latest[key]) != jsonEncode(widget.library![key])) {
            throw const ApiFailure(
              'This library changed on another device. Reload it before saving.',
            );
          }
        }
      }
      await widget.repository.api.request(
        id == null
            ? '/api/v1/libraries'
            : '/api/v1/libraries/${Uri.encodeComponent(id)}',
        method: id == null ? 'POST' : 'PATCH',
        body: patch,
      );
      widget.repository.refreshContent();
      if (mounted) {
        setState(() => _saved = true);
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  Future<void> _browse() async {
    final value = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ServerFolderPicker(
          repository: widget.repository,
          initial: _inputs['root']!.text,
        ),
      ),
    );
    if (value == null || !mounted) return;
    setState(() {
      _values['root'] = value;
      _inputs['root']!.text = value;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _saved || !_busy && !_dirty,
    onPopInvokedWithResult: (popped, _) async {
      if (popped || _busy) return;
      if (await confirm(
            context,
            'Discard Changes',
            'Discard your unsaved changes?',
          ) &&
          context.mounted) {
        setState(() => _saved = true);
        Navigator.pop(context);
      }
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          tr(context, widget.library == null ? 'Add Library' : 'Edit Library'),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : _save,
            child: Text(tr(context, 'Save')),
          ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (_busy) const LinearProgressIndicator(),
            for (final key in [
              'name',
              'root',
              'oneshotsDirectory',
              'scanDirectoryExclusions',
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: TextField(
                  controller: _inputs[key],
                  minLines: key == 'scanDirectoryExclusions' ? 3 : 1,
                  maxLines: key == 'scanDirectoryExclusions' ? 6 : 1,
                  decoration: InputDecoration(
                    labelText: tr(
                      context,
                      {
                        'name': 'Name',
                        'root': 'Root Folder',
                        'oneshotsDirectory': 'One Shot Folder',
                        'scanDirectoryExclusions':
                            'Excluded Folders (one per line)',
                      }[key]!,
                    ),
                    suffixIcon: key == 'root'
                        ? IconButton(
                            tooltip: tr(context, 'Browse'),
                            onPressed: _browse,
                            icon: const Icon(CupertinoIcons.folder),
                          )
                        : null,
                  ),
                  onChanged: (v) => setState(
                    () => _values[key] = key == 'scanDirectoryExclusions'
                        ? v.split('\n')
                        : v,
                  ),
                ),
              ),
            for (final key in ['scanInterval', 'seriesCover'])
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  tr(
                    context,
                    key == 'scanInterval' ? 'Scan Interval' : 'Series Cover',
                  ),
                ),
                subtitle: Text(text(_values[key]).replaceAll('_', ' ')),
                onTap: () async {
                  final values = key == 'scanInterval'
                      ? [
                          'DISABLED',
                          'HOURLY',
                          'EVERY_6H',
                          'EVERY_12H',
                          'DAILY',
                          'WEEKLY',
                        ]
                      : [
                          'FIRST',
                          'FIRST_UNREAD_OR_FIRST',
                          'FIRST_UNREAD_OR_LAST',
                          'LAST',
                        ];
                  final selected = await chooseValue(
                    context,
                    title: key == 'scanInterval'
                        ? 'Scan Interval'
                        : 'Series Cover',
                    selected: text(_values[key]),
                    choices: {
                      for (final v in values) v: v.replaceAll('_', ' '),
                    },
                  );
                  if (selected != null && mounted) {
                    setState(() => _values[key] = selected);
                  }
                },
              ),
            for (final flag in libraryFlags.entries)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr(context, flag.value)),
                value: _values[flag.key] == true,
                onChanged: (v) => setState(() => _values[flag.key] = v),
              ),
          ],
        ),
      ),
    ),
  );
}

class ServerFolderPicker extends StatefulWidget {
  const ServerFolderPicker({
    super.key,
    required this.repository,
    this.initial = '',
  });
  final Repository repository;
  final String initial;
  @override
  State<ServerFolderPicker> createState() => _ServerFolderPickerState();
}

class _ServerFolderPickerState extends State<ServerFolderPicker> {
  late String _path;
  late Future<Json> _future;
  @override
  void initState() {
    super.initState();
    _path = widget.initial;
    _load();
  }

  void _load() {
    _future = widget.repository.api
        .request(
          '/api/v1/filesystem',
          method: 'POST',
          body: {'path': _path, 'showFiles': false},
        )
        .then(object);
  }

  void _go(String path) => setState(() {
    _path = path;
    _load();
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'Root Folder')),
      actions: [
        TextButton(
          onPressed: _path.isEmpty ? null : () => Navigator.pop(context, _path),
          child: Text(tr(context, 'Choose')),
        ),
      ],
    ),
    body: FutureBuilder<Json>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return FailureView(error: snapshot.error!, retry: () => _go(_path));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator.adaptive());
        }
        final data = snapshot.data!;
        return ListView(
          children: [
            ListTile(
              title: SelectableText(
                _path.isEmpty ? tr(context, 'Server Folders') : _path,
              ),
            ),
            if (data['parent'] != null)
              ListTile(
                leading: const Icon(CupertinoIcons.arrow_up),
                title: Text(tr(context, 'Parent Folder')),
                onTap: () => _go(text(data['parent'])),
              ),
            for (final item in (data['directories'] as List? ?? []).map(object))
              ListTile(
                leading: const Icon(CupertinoIcons.folder),
                title: Text(text(item['name'])),
                onTap: () => _go(text(item['path'])),
              ),
          ],
        );
      },
    ),
  );
}
