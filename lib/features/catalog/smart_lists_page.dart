import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/catalog_tools.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'catalog_page.dart';
import 'filter_page.dart';
import 'list_actions.dart';
import 'server_smart_lists.dart';

class SmartListsPage extends StatefulWidget {
  const SmartListsPage({super.key, required this.repository});
  final Repository repository;
  @override
  State<SmartListsPage> createState() => _SmartListsPageState();
}

class _SmartListsPageState extends State<SmartListsPage> {
  CatalogTools get _tools => CatalogTools(widget.repository);
  bool _smart = true;
  Future<void> _edit([FilterPreset? preset]) async {
    final kind =
        preset?.kind ??
        await chooseValue(
          context,
          title: 'Content',
          selected: 'books',
          choices: {'books': 'Books', 'series': 'Series'},
        );
    if (kind == null || !mounted) return;
    final result = await Navigator.push<FilterSelection>(
      context,
      MaterialPageRoute(
        builder: (_) => FilterPage(
          repository: widget.repository,
          kind: kind,
          initial: preset?.filter ?? CatalogFilter(),
          search: preset?.search ?? '',
          sort: preset?.sort ?? 'metadata.titleSort,asc',
        ),
      ),
    );
    if (result == null || !mounted) return;
    final name = await askName(
      context,
      preset == null ? 'Save Filter' : 'Name',
      initial: preset?.name,
    );
    if (name == null) return;
    _tools.savePreset(
      preset == null
          ? FilterPreset.create(
              name,
              kind,
              result.filter,
              search: result.search,
              sort: result.sort,
              smart: _smart,
            )
          : FilterPreset(
              id: preset.id,
              name: name,
              kind: kind,
              filter: result.filter,
              search: result.search,
              sort: result.sort,
              smart: preset.smart,
            ),
    );
  }

  void _open(FilterPreset preset) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(preset.name)),
        body: CatalogPageView(
          repository: widget.repository,
          kind: preset.kind,
          initialFilter: preset.filter,
          initialSearch: preset.search,
          initialSort: preset.sort,
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.repository.catalogChanges,
    builder: (context, _) {
      final pins = _tools.pinned('presets');
      final values = _tools.presets.toList()
        ..sort((a, b) {
          final pin =
              (pins.contains(b.id) ? 1 : 0) - (pins.contains(a.id) ? 1 : 0);
          return pin != 0
              ? pin
              : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(
                        value: true,
                        label: Text(tr(context, 'Smart Lists')),
                      ),
                      ButtonSegment(
                        value: false,
                        label: Text(tr(context, 'Saved Filters')),
                      ),
                    ],
                    selected: {_smart},
                    onSelectionChanged: (v) => setState(() => _smart = v.first),
                  ),
                ),
                if (!_smart)
                  IconButton(
                    tooltip: tr(context, 'Add'),
                    onPressed: _edit,
                    icon: const Icon(CupertinoIcons.add),
                  ),
              ],
            ),
          ),
          if (_smart)
            Expanded(child: ServerSmartListsPage(repository: widget.repository))
          else
            Expanded(
              child: values.isEmpty
                  ? Center(child: Text(tr(context, 'No Results')))
                  : ListView.builder(
                      itemCount: values.length,
                      itemBuilder: (context, index) {
                        final p = values[index];
                        return ListTile(
                          leading: Icon(
                            pins.contains(p.id)
                                ? CupertinoIcons.pin_fill
                                : CupertinoIcons
                                      .line_horizontal_3_decrease_circle,
                          ),
                          title: Text(p.name),
                          subtitle: Text(
                            tr(context, p.kind == 'books' ? 'Books' : 'Series'),
                          ),
                          onTap: () => _open(p),
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) async {
                              if (action == 'edit') {
                                await _edit(p);
                                return;
                              }
                              if (action == 'pin') _tools.pin('presets', p.id);
                              if (action == 'delete' &&
                                  await confirm(
                                    context,
                                    'Delete',
                                    'Delete this saved filter?',
                                  )) {
                                _tools.deletePreset(p.id);
                              }
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'edit',
                                child: Text(tr(context, 'Edit')),
                              ),
                              PopupMenuItem(
                                value: 'pin',
                                child: Text(
                                  tr(
                                    context,
                                    pins.contains(p.id) ? 'Unpin' : 'Pin',
                                  ),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(tr(context, 'Delete')),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
        ],
      );
    },
  );
}
