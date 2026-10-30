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
import 'filter_page.dart';
import '../../ui/wheel_scroll.dart';

class ServerSmartListsPage extends StatefulWidget {
  const ServerSmartListsPage({super.key, required this.repository});
  final Repository repository;
  @override
  State<ServerSmartListsPage> createState() => _ServerSmartListsPageState();
}

class _ServerSmartListsPageState extends State<ServerSmartListsPage> {
  late Future<List<Json>?> _future;
  String? _account;
  SmartLists get _service => SmartLists(widget.repository);
  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Json>?> _load() async {
    final result = await _service.load();
    if (result != null) _account = await _service.account();
    return result;
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  Future<void> _edit([Json? item]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ServerSmartListEditor(repository: widget.repository, item: item),
      ),
    );
    if (saved == true && mounted) await _refresh();
  }

  void _open(Json item) {
    final kind = item['target'] == 'BOOK' ? 'books' : 'series';
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(text(item['name']))),
          body: CatalogPageView(
            repository: widget.repository,
            kind: kind,
            path:
                '/api/v1/smart-lists/${Uri.encodeComponent(text(item['id']))}/$kind',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Json>?>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return FailureView(error: snapshot.error!, retry: _refresh);
      }
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator.adaptive());
      }
      if (snapshot.data == null) {
        return const EmptyView(
          title: 'Smart Lists',
          message: 'smartlist.unavailable.description',
          icon: CupertinoIcons.line_horizontal_3_decrease_circle,
        );
      }
      return ListenableBuilder(
        listenable: widget.repository.catalogChanges,
        builder: (context, _) {
          final tools = CatalogTools(widget.repository),
              pins = CatalogTools(widget.repository).pinned('smart-lists');
          final items = [...snapshot.data!]
            ..sort((a, b) {
              final order =
                  (pins.contains(b['id']) ? 1 : 0) -
                  (pins.contains(a['id']) ? 1 : 0);
              return order == 0
                  ? text(a['name'])
                        .toLowerCase()
                        .compareTo(text(b['name']).toLowerCase())
                  : order;
            });
          return Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: tr(context, 'smartlist.create.title'),
                  onPressed: () => _edit(),
                  icon: const Icon(CupertinoIcons.add),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: items.isEmpty ? 1 : items.length,
                    itemBuilder: (context, index) {
                      if (items.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.all(32),
                          child: Center(child: Text(tr(context, 'No Results'))),
                        );
                      }
                      final item = items[index], id = text(item['id']);
                      final writable =
                          widget.repository.profile.admin ||
                          item['ownerId'] == _account;
                      return ListTile(
                        leading: Icon(
                          pins.contains(id)
                              ? CupertinoIcons.pin_fill
                              : CupertinoIcons
                                    .line_horizontal_3_decrease_circle,
                        ),
                        title: Text(text(item['name'])),
                        subtitle: Text(
                          [
                            tr(
                              context,
                              item['target'] == 'BOOK' ? 'Books' : 'Series',
                            ),
                            if (item['visibility'] != 'PRIVATE')
                              tr(
                                context,
                                'smartlist.visibility.${text(item['visibility']).toLowerCase()}',
                              ),
                            if (text(item['summary']).isNotEmpty)
                              text(item['summary']),
                          ].join(' · '),
                        ),
                        onTap: () => _open(item),
                        trailing: PopupMenuButton<String>(
                          onSelected: (action) async {
                            if (action == 'pin') {
                              tools.pin('smart-lists', id);
                              return;
                            }
                            if (action == 'edit') {
                              await _edit(item);
                              return;
                            }
                            if (action == 'delete' &&
                                await confirm(
                                  context,
                                  'Delete',
                                  'Delete this smart list?',
                                )) {
                              try {
                                await _service.delete(item);
                                if (mounted) await _refresh();
                              } catch (e) {
                                if (context.mounted) showError(context, e);
                              }
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'pin',
                              child: Text(
                                tr(
                                  context,
                                  pins.contains(id) ? 'Unpin' : 'Pin',
                                ),
                              ),
                            ),
                            if (writable) ...[
                              PopupMenuItem(
                                value: 'edit',
                                child: Text(tr(context, 'Edit')),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(tr(context, 'Delete')),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ).withWheelScrolling(),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

class ServerSmartListEditor extends StatefulWidget {
  const ServerSmartListEditor({
    super.key,
    required this.repository,
    this.item,
    this.kind = 'books',
    this.initial,
  });
  final Repository repository;
  final Json? item;
  final String kind;
  final FilterSelection? initial;
  @override
  State<ServerSmartListEditor> createState() => _ServerSmartListEditorState();
}

class _ServerSmartListEditorState extends State<ServerSmartListEditor> {
  final _name = TextEditingController(),
      _summary = TextEditingController(),
      _query = TextEditingController();
  late Future<void> _future;
  Json? _original;
  Json _search = {};
  String _target = 'BOOK', _visibility = 'PRIVATE';
  final _shared = <String>[];
  bool _ready = false, _busy = false, _saved = false;
  String _baseline = '';
  String get _kind => _target == 'BOOK' ? 'books' : 'series';
  SmartLists get _service => SmartLists(widget.repository);
  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<void> _load() async {
    final item = widget.item == null
        ? null
        : await _service.get(text(widget.item!['id']));
    if (!mounted) return;
    _original = item;
    _target = text(item?['target'], widget.kind == 'books' ? 'BOOK' : 'SERIES');
    _name.text = text(item?['name']);
    _summary.text = text(item?['summary']);
    _search = object(
      jsonDecode(
        jsonEncode(
          item?['search'] ??
              {
                'condition': ?widget.initial?.filter.condition(_kind),
                'fullTextSearch': widget.initial?.search ?? '',
              },
        ),
      ),
    );
    _query.text = text(_search['fullTextSearch']);
    _visibility = text(item?['visibility'], 'PRIVATE');
    _shared.clear();
    _shared.addAll(
      (item?['sharedWithUserIds'] as List? ?? []).whereType<String>(),
    );
    _baseline = jsonEncode(_values);
    setState(() => _ready = true);
  }

  Json get _values => {
    'name': _name.text.trim(),
    'summary': _summary.text.trim(),
    if (_original == null) 'target': _target,
    'search': {
      ..._search,
      if (_query.text.trim().isNotEmpty) 'fullTextSearch': _query.text.trim(),
    },
    if (widget.repository.profile.admin) ...{
      'visibility': _visibility,
      'sharedWithUserIds': _visibility == 'SHARED' ? [..._shared] : <String>[],
    },
  };
  Json get _patch => {
    for (final e in _values.entries)
      if (_original == null ||
          jsonEncode(_original![e.key]) != jsonEncode(e.value))
        e.key: e.value,
  };
  bool get _dirty => _ready && jsonEncode(_values) != _baseline;
  Future<void> _filters() async {
    final selection = await Navigator.push<FilterSelection>(
      context,
      MaterialPageRoute(
        builder: (_) => FilterPage(
          repository: widget.repository,
          kind: _kind,
          initial: CatalogFilter.fromCondition(
            object(_search['condition']),
            _kind,
          ),
          search: _query.text,
        ),
      ),
    );
    if (selection == null || !mounted) return;
    setState(() {
      _search = {..._search}
        ..remove('condition')
        ..remove('fullTextSearch');
      final condition = selection.filter.condition(_kind);
      if (condition != null) _search['condition'] = condition;
      _query.text = selection.search;
    });
  }

  Future<void> _targets() async {
    try {
      final users = await _service.targets();
      if (!mounted) return;
      final selected = _shared.toSet();
      final choices = {
        for (final user in users) text(user['id']): text(user['email']),
        for (final id in _shared)
          if (!users.any((u) => u['id'] == id))
            id: '${tr(context, 'Unavailable User')} ($id)',
      };
      final result = await showDialog<List<String>>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text(tr(context, 'Share With')),
            content: SizedBox(
              width: 440,
              child: choices.isEmpty
                  ? Text(tr(context, 'smartlist.sharedWith.empty'))
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final user in choices.entries)
                          CheckboxListTile(
                            title: Text(user.value),
                            value: selected.contains(user.key),
                            onChanged: (v) => update(() {
                              if (v == true) {
                                selected.add(user.key);
                              } else {
                                selected.remove(user.key);
                              }
                            }),
                          ),
                      ],
                    ).withWheelScrolling(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr(context, 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, selected.toList()),
                child: Text(tr(context, 'Done')),
              ),
            ],
          ),
        ),
      );
      if (result != null && mounted) {
        setState(() {
          _shared.clear();
          _shared.addAll(result);
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _save() async {
    if (!_ready || _busy) return;
    if (_name.text.trim().isEmpty) {
      showError(context, const FormatException('Name is required.'));
      return;
    }
    try {
      setState(() => _busy = true);
      if (_patch.isNotEmpty) await _service.save(_patch, original: _original);
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

  @override
  void dispose() {
    _name.dispose();
    _summary.dispose();
    _query.dispose();
    super.dispose();
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
          tr(
            context,
            widget.item == null
                ? 'smartlist.create.title'
                : 'smartlist.edit.title',
          ),
        ),
        actions: [
          TextButton(
            onPressed: _ready && !_busy ? _save : null,
            child: Text(tr(context, 'Save')),
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return FailureView(
              error: snapshot.error!,
              retry: () => setState(() => _future = _load()),
            );
          }
          if (!_ready) {
            return const Center(child: CircularProgressIndicator.adaptive());
          }
          return AbsorbPointer(
            absorbing: _busy,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (_busy) const LinearProgressIndicator(),
                TextField(
                  controller: _name,
                  decoration: InputDecoration(
                    labelText: tr(context, 'smartlist.name'),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _summary,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: tr(context, 'Summary'),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr(context, 'smartlist.target')),
                  subtitle: Text(
                    tr(context, _kind == 'books' ? 'Books' : 'Series'),
                  ),
                  onTap: _original != null
                      ? null
                      : () async {
                          final target = await chooseValue(
                            context,
                            title: 'smartlist.target',
                            selected: _target,
                            choices: {'BOOK': 'Books', 'SERIES': 'Series'},
                          );
                          if (target == null ||
                              !context.mounted ||
                              target == _target) {
                            return;
                          }
                          if (_search.isNotEmpty &&
                              !await confirm(
                                context,
                                'Change Content',
                                'Clear filters when changing the content type?',
                              )) {
                            return;
                          }
                          if (mounted) {
                            setState(() {
                              _target = target;
                              _search = {};
                              _query.clear();
                            });
                          }
                        },
                ),
                TextField(
                  controller: _query,
                  decoration: InputDecoration(
                    labelText: tr(context, 'smartlist.filters.searchText'),
                  ),
                  onChanged: (value) =>
                      setState(() => _search.remove('fullTextSearch')),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr(context, 'Filters')),
                  trailing: const Icon(CupertinoIcons.chevron_right),
                  onTap: _filters,
                ),
                if (widget.repository.profile.admin) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr(context, 'smartlist.visibility')),
                    subtitle: Text(
                      tr(
                        context,
                        'smartlist.visibility.${_visibility.toLowerCase()}',
                      ),
                    ),
                    onTap: () async {
                      final value = await chooseValue(
                        context,
                        title: 'smartlist.visibility',
                        selected: _visibility,
                        choices: {
                          for (final v in ['PRIVATE', 'PUBLIC', 'SHARED'])
                            v: 'smartlist.visibility.${v.toLowerCase()}',
                        },
                      );
                      if (value != null && mounted) {
                        setState(() => _visibility = value);
                      }
                    },
                  ),
                  if (_visibility == 'SHARED')
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr(context, 'Share With')),
                      subtitle: Text(
                        '${_shared.length} ${tr(context, 'Users')}',
                      ),
                      onTap: _targets,
                    ),
                ],
              ],
            ).withWheelScrolling(),
          );
        },
      ),
    ),
  );
}
