import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/catalog_tools.dart';
import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'catalog_page.dart';

class ListEditor extends StatefulWidget {
  const ListEditor({super.key, required this.repository, required this.item});
  final Repository repository;
  final CatalogItem item;
  @override
  State<ListEditor> createState() => _ListEditorState();
}

class _ListEditorState extends State<ListEditor> {
  final _name = TextEditingController(), _summary = TextEditingController();
  late Future<void> _loadFuture;
  Json _original = {};
  List<String> _ids = [];
  final _members = <String, CatalogItem>{};
  bool _ordered = false,
      _ready = false,
      _busy = false,
      _dirty = false,
      _leaving = false;
  String get _idsKey =>
      widget.item.kind == 'readlists' ? 'bookIds' : 'seriesIds';
  String get _memberKind =>
      widget.item.kind == 'readlists' ? 'books' : 'series';
  @override
  void initState() {
    super.initState();
    _loadFuture = _load();
  }

  Future<void> _load() async {
    final tools = CatalogTools(widget.repository);
    final data = await tools.list(widget.item.kind, widget.item.id);
    final children = await tools.all(
      _memberKind,
      path:
          '/api/v1/${widget.item.kind}/${Uri.encodeComponent(widget.item.id)}/$_memberKind',
    );
    if (!mounted) return;
    _original = data;
    _name.text = text(data['name']);
    _summary.text = text(data['summary']);
    _ordered = data['ordered'] == true;
    _ids = (data[_idsKey] as List? ?? []).map((id) => '$id').toList();
    _members.addAll({for (final item in children) item.id: item});
    setState(() => _ready = true);
  }

  @override
  void dispose() {
    _name.dispose();
    _summary.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final values = await pickCatalogItems(
      context,
      widget.repository,
      _memberKind,
    );
    if (values == null || !mounted) return;
    setState(() {
      for (final item in values) {
        if (!_ids.contains(item.id)) _ids.add(item.id);
        _members[item.id] = item;
      }
      _dirty = true;
    });
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      showError(context, const FormatException('Enter a name.'));
      return;
    }
    final patch = <String, dynamic>{
      if (_name.text.trim() != text(_original['name']))
        'name': _name.text.trim(),
      if (widget.item.kind == 'readlists' &&
          _summary.text != text(_original['summary']))
        'summary': _summary.text,
      if (_ordered != (_original['ordered'] == true)) 'ordered': _ordered,
      if (jsonEncode(_ids) != jsonEncode(_original[_idsKey])) _idsKey: _ids,
    };
    setState(() => _busy = true);
    try {
      if (patch.isNotEmpty) {
        await CatalogTools(widget.repository)
            .updateList(widget.item.kind, widget.item.id, _original, patch);
      }
      if (mounted) {
        setState(() => _leaving = true);
        Navigator.pop(context, 'saved');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  Future<void> _delete() async {
    if (!await confirm(
          context,
          'Delete List',
          'Delete this list? Books and series will be kept.',
        ) ||
        !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await CatalogTools(widget.repository)
          .deleteList(widget.item.kind, widget.item.id);
      if (mounted) {
        setState(() => _leaving = true);
        Navigator.pop(context, 'deleted');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<String>(
    canPop: _leaving || (!_busy && !_dirty),
    onPopInvokedWithResult: (popped, result) async {
      if (popped || _busy) return;
      if (await confirm(
            context,
            'Discard Changes',
            'Discard your unsaved changes?',
          ) &&
          context.mounted) {
        setState(() => _leaving = true);
        if (context.mounted) Navigator.pop(context);
      }
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Edit List')),
        actions: [
          IconButton(
            tooltip: tr(context, 'Delete List'),
            onPressed: _ready && !_busy ? _delete : null,
            icon: const Icon(CupertinoIcons.trash),
          ),
          IconButton(
            tooltip: tr(context, 'Save'),
            onPressed: _ready && !_busy ? _save : null,
            icon: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(CupertinoIcons.check_mark),
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _loadFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return FailureView(
              error: snapshot.error!,
              retry: () => setState(() => _loadFuture = _load()),
            );
          }
          if (!_ready) {
            return const Center(child: CircularProgressIndicator.adaptive());
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: TextField(
                  controller: _name,
                  enabled: !_busy,
                  decoration: InputDecoration(labelText: tr(context, 'Name')),
                  onChanged: (_) => setState(() => _dirty = true),
                ),
              ),
              if (widget.item.kind == 'readlists')
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: TextField(
                    controller: _summary,
                    enabled: !_busy,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: tr(context, 'Summary'),
                    ),
                    onChanged: (_) => setState(() => _dirty = true),
                  ),
                ),
              SwitchListTile(
                title: Text(tr(context, 'Ordered')),
                value: _ordered,
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        _ordered = value;
                        _dirty = true;
                      }),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('${_ids.length} ${tr(context, 'Items')}'),
                    ),
                    TextButton.icon(
                      onPressed: _busy ? null : _add,
                      icon: const Icon(CupertinoIcons.add),
                      label: Text(tr(context, 'Add')),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: _ids.length,
                  onReorderItem: (old, target) {
                    if (_busy || !_ordered) return;
                    setState(() {
                      _ids.insert(target, _ids.removeAt(old));
                      _dirty = true;
                    });
                  },
                  itemBuilder: (context, index) {
                    final id = _ids[index], item = _members[id];
                    return ListTile(
                      key: ValueKey(id),
                      title: Text(
                        item?.title ?? tr(context, 'Unavailable Item'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: item == null ? Text(id) : null,
                      leading: ReorderableDragStartListener(
                        index: index,
                        enabled: _ordered && !_busy,
                        child: Icon(
                          CupertinoIcons.line_horizontal_3,
                          color: _ordered
                              ? null
                              : Theme.of(context).disabledColor,
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: tr(context, 'Remove'),
                        onPressed: _busy || _ids.length <= 1
                            ? null
                            : () => setState(() {
                                _ids.removeAt(index);
                                _dirty = true;
                              }),
                        icon: const Icon(CupertinoIcons.minus_circle),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
