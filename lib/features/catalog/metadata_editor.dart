import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/catalog_tools.dart';
import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';

class MetadataField {
  const MetadataField(
    this.key,
    this.label, {
    this.type = 'text',
    this.options = const [],
  });
  final String key, label, type;
  final List<String> options;
}

List<MetadataField> metadataFields(String kind) => [
  const MetadataField('title', 'Title'),
  if (kind == 'series') const MetadataField('titleSort', 'Sort Title'),
  const MetadataField('summary', 'Summary', type: 'multiline'),
  if (kind == 'books') ...[
    const MetadataField('number', 'Number'),
    const MetadataField('numberSort', 'Sort Number', type: 'number'),
    const MetadataField('releaseDate', 'Release Date', type: 'date'),
    const MetadataField('isbn', 'ISBN'),
    const MetadataField('authors', 'Authors', type: 'authors'),
  ] else ...[
    const MetadataField(
      'status',
      'Status',
      type: 'enum',
      options: ['ONGOING', 'ENDED', 'ABANDONED', 'HIATUS'],
    ),
    const MetadataField(
      'readingDirection',
      'Reading Direction',
      type: 'enum',
      options: ['LEFT_TO_RIGHT', 'RIGHT_TO_LEFT', 'VERTICAL', 'WEBTOON'],
    ),
    const MetadataField('language', 'Language'),
    const MetadataField('publisher', 'Publisher'),
    const MetadataField('ageRating', 'Age Rating', type: 'integer'),
    const MetadataField('totalBookCount', 'Total Book Count', type: 'integer'),
    const MetadataField('genres', 'Genres', type: 'strings'),
    const MetadataField('sharingLabels', 'Sharing Labels', type: 'strings'),
    const MetadataField(
      'alternateTitles',
      'Alternate Titles',
      type: 'alternateTitles',
    ),
  ],
  const MetadataField('tags', 'Tags', type: 'strings'),
  const MetadataField('links', 'Links', type: 'links'),
];

Json metadataPatch(
  String kind,
  Json original,
  Json values,
  Set<String> dirty, {
  bool forceExplicit = false,
}) {
  final result = <String, dynamic>{};
  for (final field in metadataFields(kind)) {
    final key = field.key;
    if (dirty.contains(key)) {
      dynamic value = values[key];
      if (field.type == 'number' || field.type == 'integer') {
        final raw = '${value ?? ''}'.trim();
        value = raw.isEmpty ? null : num.tryParse(raw);
        if (raw.isNotEmpty &&
            (value == null ||
                !value.isFinite ||
                field.type == 'integer' && value != value.round())) {
          throw FormatException('${field.label}: enter a valid number.');
        }
        if (value != null && field.type == 'integer') value = value.toInt();
        if (value != null && field.type == 'integer' && value < 0) {
          throw FormatException('${field.label}: enter zero or greater.');
        }
      } else if (field.type == 'strings') {
        value = (value as List? ?? [])
            .map((v) => '$v'.trim())
            .where((v) => v.isNotEmpty)
            .toSet()
            .toList();
      } else if (['authors', 'links', 'alternateTitles'].contains(field.type)) {
        value = (value as List? ?? []).map((v) => object(v)).toList();
        for (final row in value as List<Json>) {
          final keys = field.type == 'authors'
              ? ['name', 'role']
              : field.type == 'links'
              ? ['label']
              : ['label', 'title'];
          for (final part in keys) {
            row[part] = text(row[part]).trim();
            if (text(row[part]).isEmpty) {
              throw FormatException(
                '${field.label}: all required values must be filled.',
              );
            }
          }
          if (field.type == 'links' && text(row['url']).isNotEmpty) {
            row['url'] = text(row['url']).trim();
            final url = Uri.tryParse(text(row['url']).trim());
            if (url == null ||
                !['http', 'https'].contains(url.scheme) ||
                url.host.isEmpty) {
              throw const FormatException('Enter an HTTP or HTTPS link.');
            }
            row['url'] = url.toString();
          }
        }
      } else {
        value = '${value ?? ''}'.trim();
        if (value.isEmpty) value = null;
        if (value != null &&
            field.type == 'enum' &&
            !field.options.contains(value)) {
          throw FormatException('${field.label}: choose a valid value.');
        }
        if (value != null && field.type == 'date') {
          final date = DateTime.tryParse(value);
          if (date == null ||
              date.toIso8601String().substring(0, 10) != value) {
            throw const FormatException('Use a valid YYYY-MM-DD date.');
          }
        }
      }
      if (forceExplicit ||
          original[key] != value &&
              jsonEncode(original[key]) != jsonEncode(value)) {
        result[key] = value;
      }
    }
    final lock = '${key}Lock';
    if (dirty.contains(lock) &&
        (forceExplicit || original[lock] != values[lock])) {
      result[lock] = values[lock] == true;
    }
  }
  return result;
}

class MetadataEditor extends StatefulWidget {
  const MetadataEditor({
    super.key,
    required this.repository,
    required this.item,
    this.items,
  });
  final Repository repository;
  final CatalogItem item;
  final List<CatalogItem>? items;
  @override
  State<MetadataEditor> createState() => _MetadataEditorState();
}

class _MetadataEditorState extends State<MetadataEditor> {
  late Future<Json> _future;
  Json _original = {}, _values = {};
  final _dirty = <String>{};
  final _inputs = <String, TextEditingController>{};
  bool _saving = false, _saved = false, _ready = false;
  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Json> _load() async {
    final dto = object(
      await widget.repository.api.request(
        '/api/v1/${widget.item.kind}/${Uri.encodeComponent(widget.item.id)}',
      ),
    );
    if (!mounted) return dto;
    _original = object(dto['metadata']);
    _values = object(jsonDecode(jsonEncode(_original)));
    setState(() => _ready = true);
    return dto;
  }

  @override
  void dispose() {
    for (final controller in _inputs.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _set(String key, dynamic value) => setState(() {
    _values[key] = value;
    _dirty.add(key);
    _values['${key}Lock'] = true;
    _dirty.add('${key}Lock');
  });
  Future<void> _save() async {
    if (!_ready || _saving) return;
    try {
      final batch = widget.items != null && widget.items!.length > 1;
      final patch = metadataPatch(
        widget.item.kind,
        batch ? {} : _original,
        _values,
        _dirty,
        forceExplicit: batch,
      );
      setState(() => _saving = true);
      for (final item in widget.items ?? [widget.item]) {
        await CatalogTools(widget.repository).updateMetadata(
          widget.item.kind,
          item.id,
          patch,
          original: item.id == widget.item.id
              ? _original
              : object(item.json['metadata']),
        );
      }
      if (!mounted) return;
      setState(() => _saved = true);
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showError(context, e);
      }
    }
  }

  Widget _input(MetadataField field) {
    final key = field.key;
    if (field.type == 'enum') {
      return OutlinedButton(
        onPressed: () async {
          final value = await chooseValue(
            context,
            title: field.label,
            selected: text(_values[key]),
            choices: {
              '': 'Not Set',
              for (final v in field.options) v: v.replaceAll('_', ' '),
            },
          );
          if (value != null && mounted) _set(key, value);
        },
        child: Text(
          text(_values[key]).isEmpty
              ? tr(context, 'Not Set')
              : text(_values[key]).replaceAll('_', ' '),
        ),
      );
    }
    if (field.type == 'strings') {
      final list = (_values[key] as List? ?? []).map((v) => '$v').toList();
      final controller = _inputs.putIfAbsent(key, TextEditingController.new);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final value in list)
                InputChip(
                  label: Text(value),
                  onDeleted: () => _set(key, [...list]..remove(value)),
                ),
            ],
          ),
          TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: tr(context, 'Add'),
              suffixIcon: IconButton(
                icon: const Icon(CupertinoIcons.add),
                onPressed: () {
                  final value = controller.text.trim();
                  if (value.isNotEmpty) {
                    _set(key, {...list, value}.toList());
                    controller.clear();
                  }
                },
              ),
            ),
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) {
                _set(key, {...list, value.trim()}.toList());
                controller.clear();
              }
            },
          ),
        ],
      );
    }
    if (['authors', 'links', 'alternateTitles'].contains(field.type)) {
      final rows = (_values[key] as List? ?? []).cast<dynamic>();
      return Column(
        children: [
          for (final dynamic value in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        for (final part
                            in field.type == 'authors'
                                ? ['name', 'role']
                                : field.type == 'links'
                                ? ['label', 'url']
                                : ['label', 'title'])
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: TextFormField(
                              key: ValueKey(
                                '$key:${identityHashCode(value)}:$part',
                              ),
                              initialValue: text(object(value)[part]),
                              decoration: InputDecoration(
                                labelText: tr(
                                  context,
                                  {
                                    'name': 'Name',
                                    'role': 'Role',
                                    'label': 'Label',
                                    'url': 'URL',
                                    'title': 'Title',
                                  }[part]!,
                                ),
                              ),
                              onChanged: (content) {
                                (value as Map)[part] = content;
                                _set(key, rows);
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: tr(context, 'Remove'),
                    onPressed: () => _set(key, [...rows]..remove(value)),
                    icon: const Icon(CupertinoIcons.minus_circle),
                  ),
                ],
              ),
            ),
          TextButton.icon(
            onPressed: () => _set(key, [...rows, <String, dynamic>{}]),
            icon: const Icon(CupertinoIcons.add),
            label: Text(tr(context, 'Add')),
          ),
        ],
      );
    }
    return TextFormField(
      initialValue: '${_values[key] ?? ''}',
      decoration: InputDecoration(
        hintText: field.type == 'date' ? 'YYYY-MM-DD' : null,
      ),
      maxLines: field.type == 'multiline' ? 5 : 1,
      keyboardType: field.type == 'number' || field.type == 'integer'
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      onChanged: (value) => _set(key, value),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<bool>(
    canPop: _dirty.isEmpty || _saved,
    onPopInvokedWithResult: (popped, result) async {
      if (popped || _saving) return;
      if (await confirm(
            context,
            'Discard Changes',
            'Discard your unsaved changes?',
          ) &&
          context.mounted) {
        setState(() => _saved = true);
        if (context.mounted) Navigator.pop(context, false);
      }
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Edit Metadata')),
        actions: [
          IconButton(
            tooltip: tr(context, 'Save'),
            onPressed: _saving || !_ready ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(CupertinoIcons.check_mark),
          ),
        ],
      ),
      body: FutureBuilder<Json>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return FailureView(
              error: snapshot.error!,
              retry: () => setState(() => _future = _load()),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator.adaptive());
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (widget.items != null && widget.items!.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    tr(
                      context,
                      'Only changed fields will be applied to every selected item.',
                    ),
                  ),
                ),
              for (final field in metadataFields(widget.item.kind))
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              tr(context, field.label),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            tooltip: tr(
                              context,
                              _values['${field.key}Lock'] == true
                                  ? 'Unlock'
                                  : 'Lock',
                            ),
                            onPressed: () => setState(() {
                              _values['${field.key}Lock'] =
                                  _values['${field.key}Lock'] != true;
                              _dirty.add('${field.key}Lock');
                            }),
                            icon: Icon(
                              _values['${field.key}Lock'] == true
                                  ? CupertinoIcons.lock_fill
                                  : CupertinoIcons.lock_open,
                            ),
                          ),
                        ],
                      ),
                      _input(field),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}
