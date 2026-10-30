import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/catalog_tools.dart';
import '../../core/models.dart';
import '../../core/repository.dart';
import '../../core/smart_lists.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'catalog_page.dart';
import 'list_actions.dart';
import 'server_smart_lists.dart';
import '../../ui/wheel_scroll.dart';

class FilterSelection {
  const FilterSelection(this.filter, this.search, this.sort);
  final CatalogFilter filter;
  final String search, sort;
}

const operatorLabels = {
  'is': 'Is',
  'isNot': 'Is Not',
  'contains': 'Contains',
  'doesNotContain': 'Does Not Contain',
  'beginsWith': 'Begins With',
  'doesNotBeginWith': 'Does Not Begin With',
  'endsWith': 'Ends With',
  'doesNotEndWith': 'Does Not End With',
  'greaterThan': 'Greater Than',
  'lessThan': 'Less Than',
  'before': 'Before',
  'after': 'After',
  'isInTheLast': 'In the Last',
  'isNotInTheLast': 'Not in the Last',
  'isNull': 'Is Empty',
  'isNotNull': 'Is Not Empty',
  'isTrue': 'Yes',
  'isFalse': 'No',
};

class FilterPage extends StatefulWidget {
  const FilterPage({
    super.key,
    required this.repository,
    required this.kind,
    required this.initial,
    this.search = '',
    this.sort = 'metadata.titleSort,asc',
  });
  final Repository repository;
  final String kind, search, sort;
  final CatalogFilter initial;
  @override
  State<FilterPage> createState() => _FilterPageState();
}

class _FilterPageState extends State<FilterPage> {
  late Json _root;
  late String _query, _sort;
  @override
  void initState() {
    super.initState();
    _root = object(jsonDecode(jsonEncode(widget.initial.toJson())));
    _query = widget.search;
    _sort = widget.sort;
  }

  CatalogFilter get _filter => CatalogFilter.fromJson(_root);
  Future<void> _save(bool smart) async {
    try {
      _filter.condition(widget.kind);
      if (smart) {
        final available = await SmartLists(widget.repository).load();
        if (!mounted) return;
        if (available == null) {
          showError(context, tr(context, 'smartlist.unavailable.description'));
          return;
        }
        await Navigator.push(
          context,
          MaterialPageRoute<bool>(
            builder: (_) => ServerSmartListEditor(
              repository: widget.repository,
              kind: widget.kind,
              initial: FilterSelection(_filter, _query, _sort),
            ),
          ),
        );
        return;
      }
      final name = await askName(
        context,
        smart ? 'Create Smart List' : 'Save Filter',
      );
      if (name == null || !mounted) return;
      CatalogTools(widget.repository).savePreset(
        FilterPreset.create(
          name,
          widget.kind,
          _filter,
          search: _query,
          sort: _sort,
          smart: smart,
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr(context, 'Saved'))));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _presets() async {
    final values = CatalogTools(widget.repository).presets
        .where((p) => p.kind == widget.kind)
        .toList();
    if (values.isEmpty) return;
    final choice = await chooseValue(
      context,
      title: 'Saved Filters',
      selected: '',
      choices: {for (final p in values) p.id: p.name},
      translateChoices: false,
      searchable: true,
    );
    if (choice == null || !mounted) return;
    final filter = values.firstWhere((p) => p.id == choice);
    setState(() {
      _root = object(jsonDecode(jsonEncode(filter.filter.toJson())));
      _query = filter.search;
      _sort = filter.sort;
    });
  }

  Future<void> _chooseReference(Json row) async {
    try {
      final field = text(row['field']);
      if (field == 'libraryId') {
        final libraries = (await widget.repository.get(
          '/api/v1/libraries',
          cacheFirst: true,
        ) as List).map(object).toList();
        if (!mounted) return;
        final id = await chooseValue(
          context,
          title: 'Library',
          selected: text(row['value']),
          choices: {
            for (final item in libraries) text(item['id']): text(item['name']),
          },
          translateChoices: false,
          searchable: true,
        );
        if (id != null && mounted) {
          setState(() {
            row['value'] = id;
            row['label'] = text(
              libraries.firstWhere((v) => v['id'] == id)['name'],
            );
          });
        }
      } else {
        final item = await pickCatalogItem(
          context,
          widget.repository,
          {
            'seriesId': 'series',
            'readListId': 'readlists',
            'collectionId': 'collections',
          }[field]!,
        );
        if (item != null && mounted) {
          setState(() {
            row['value'] = item.id;
            row['label'] = item.title;
          });
        }
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _group(Json group, {bool root = false}) {
    final entries = (group['entries'] as List).cast<dynamic>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text(tr(context, 'Match All')),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(tr(context, 'Match Any')),
                    ),
                  ],
                  selected: {group['any'] == true},
                  onSelectionChanged: (value) =>
                      setState(() => group['any'] = value.first),
                ),
              ),
            ],
          ),
        ),
        for (var i = 0; i < entries.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entries[i] is Map &&
                                    (entries[i] as Map).containsKey('entries')
                                ? tr(context, 'Filter Group')
                                : tr(
                                    context,
                                    filterLabels[text(
                                          object(entries[i])['field'],
                                        )] ??
                                        'Filter',
                                  ),
                          ),
                        ),
                        IconButton(
                          tooltip: tr(context, 'Remove'),
                          onPressed: () => setState(() => entries.removeAt(i)),
                          icon: const Icon(CupertinoIcons.minus_circle),
                        ),
                      ],
                    ),
                    if ((entries[i] as Map).containsKey('entries'))
                      _group(entries[i] as Json)
                    else
                      _rule(entries[i] as Json),
                  ],
                ),
              ),
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () => setState(
                () => entries.add(<String, dynamic>{
                  'field': 'title',
                  'operator': 'contains',
                  'value': '',
                }),
              ),
              icon: const Icon(CupertinoIcons.add),
              label: Text(tr(context, 'Add Filter')),
            ),
            TextButton.icon(
              onPressed: () => setState(
                () => entries.add(<String, dynamic>{
                  'any': false,
                  'entries': <dynamic>[],
                }),
              ),
              icon: const Icon(CupertinoIcons.folder_badge_plus),
              label: Text(tr(context, 'Add Group')),
            ),
          ],
        ),
      ],
    );
  }

  Widget _rule(Json row) {
    if (row['raw'] is Map) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr(
              context,
              'This condition is preserved. Remove it only if you want to replace it.',
            ),
          ),
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(row['raw']),
          ),
        ],
      );
    }
    final field = text(row['field']);
    final op = text(row['operator']);
    final unary = ['isNull', 'isNotNull', 'isTrue', 'isFalse'].contains(op);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton(
          onPressed: () async {
            final value = await chooseValue(
              context,
              title: 'Field',
              selected: field,
              choices: {
                for (final key in filterFields(widget.kind))
                  key: filterLabels[key]!,
              },
            );
            if (value == null || !mounted) return;
            setState(() {
              row['field'] = value;
              row['operator'] = filterOperators(value).first;
              row['value'] = '';
              row.remove('label');
            });
          },
          child: Text(tr(context, filterLabels[field] ?? field)),
        ),
        OutlinedButton(
          onPressed: () async {
            final value = await chooseValue(
              context,
              title: 'Condition',
              selected: op,
              choices: {
                for (final key in filterOperators(field))
                  key: operatorLabels[key] ?? key,
              },
            );
            if (value != null && mounted) {
              setState(() => row['operator'] = value);
            }
          },
          child: Text(tr(context, operatorLabels[op] ?? op)),
        ),
        if (!unary &&
            [
              'libraryId',
              'seriesId',
              'readListId',
              'collectionId',
            ].contains(field))
          OutlinedButton(
            onPressed: () => _chooseReference(row),
            child: Text(
              text(row['label'], text(row['value'])).isEmpty
                  ? tr(context, 'Choose')
                  : text(row['label'], text(row['value'])),
            ),
          )
        else if (!unary && filterEnums[field] != null)
          OutlinedButton(
            onPressed: () async {
              final value = await chooseValue(
                context,
                title: filterLabels[field] ?? field,
                selected: text(row['value']),
                choices: {
                  for (final key in filterEnums[field]!)
                    key: key.replaceAll('_', ' '),
                },
              );
              if (value != null && mounted) {
                setState(() => row['value'] = value);
              }
            },
            child: Text(
              text(row['value']).isEmpty
                  ? tr(context, 'Choose')
                  : text(row['value']).replaceAll('_', ' '),
            ),
          )
        else if (!unary)
          TextFormField(
            key: ValueKey('${identityHashCode(row)}:$field:$op'),
            initialValue: text(row['value']),
            decoration: InputDecoration(
              labelText: tr(
                context,
                field == 'releaseDate'
                    ? (op == 'after' || op == 'before' ? 'YYYY-MM-DD' : 'Days')
                    : 'Value',
              ),
            ),
            keyboardType: ['ageRating', 'numberSort'].contains(field)
                ? const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  )
                : TextInputType.text,
            onChanged: (value) => row['value'] = value,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'Advanced Filters')),
      actions: [
        PopupMenuButton<String>(
          onSelected: (action) {
            if (action == 'save') _save(false);
            if (action == 'smart') _save(true);
            if (action == 'load') _presets();
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'save',
              child: Text(tr(context, 'Save Filter')),
            ),
            PopupMenuItem(
              value: 'smart',
              child: Text(tr(context, 'Create Smart List')),
            ),
            PopupMenuItem(
              value: 'load',
              child: Text(tr(context, 'Saved Filters')),
            ),
          ],
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _group(_root, root: true),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () {
            try {
              _filter.condition(widget.kind);
              Navigator.pop(context, FilterSelection(_filter, _query, _sort));
            } catch (e) {
              showError(context, e);
            }
          },
          child: Text(tr(context, 'Apply')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            FilterSelection(CatalogFilter(), _query, _sort),
          ),
          child: Text(tr(context, 'Clear Filters')),
        ),
      ],
    ).withWheelScrolling(),
  );
}
