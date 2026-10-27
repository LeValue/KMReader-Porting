import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/catalog_tools.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'detail_page.dart';
import 'filter_page.dart';
import 'list_actions.dart';
import 'metadata_editor.dart';

Future<List<CatalogItem>?> pickCatalogItems(
  BuildContext context,
  Repository repository,
  String kind,
) => Navigator.push<List<CatalogItem>>(
  context,
  MaterialPageRoute(
    builder: (_) => Scaffold(
      appBar: AppBar(
        title: Text(
          tr(context, kind == 'books' ? 'Select Books' : 'Select Series'),
        ),
      ),
      body: CatalogPageView(
        repository: repository,
        kind: kind,
        onPicked: (items) => Navigator.pop(context, items),
      ),
    ),
  ),
);

Future<CatalogItem?> pickCatalogItem(
  BuildContext context,
  Repository repository,
  String kind,
) => Navigator.push<CatalogItem>(
  context,
  MaterialPageRoute(
    builder: (_) => Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Choose'))),
      body: CatalogPageView(
        repository: repository,
        kind: kind,
        path: kind == 'readlists' || kind == 'collections'
            ? '/api/v1/$kind'
            : null,
        onItemPicked: (item) => Navigator.pop(context, item),
      ),
    ),
  ),
);

void openItem(BuildContext context, Repository repository, CatalogItem item) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DetailPage(repository: repository, item: item),
    ),
  );
}

class CatalogPageView extends StatefulWidget {
  const CatalogPageView({
    super.key,
    required this.repository,
    this.kind = 'series',
    this.title,
    this.condition,
    this.path,
    this.searchEnabled = true,
    this.readListId,
    this.libraryId,
    this.initialSort,
    this.onPicked,
    this.initialFilter,
    this.initialSearch,
    this.onItemPicked,
  });
  final Repository repository;
  final String kind;
  final String? title, path;
  final Json? condition;
  final bool searchEnabled;
  final String? readListId;
  final String? libraryId, initialSort;
  final ValueChanged<List<CatalogItem>>? onPicked;
  final CatalogFilter? initialFilter;
  final String? initialSearch;
  final ValueChanged<CatalogItem>? onItemPicked;
  @override
  State<CatalogPageView> createState() => _CatalogPageViewState();
}

class _CatalogPageViewState extends State<CatalogPageView> {
  bool get _canFilter =>
      widget.path == null || widget.path!.startsWith('/api/v1/smart-lists/');
  final _scroll = ScrollController();
  final _search = TextEditingController();
  List<CatalogItem> _items = [];
  bool _busy = false, _last = false;
  int _page = 0;
  int _generation = 0;
  Object? _error;
  String _query = '', _sort = 'metadata.titleSort,asc', _readStatus = '';
  bool _list = false;
  bool _selecting = false, _acting = false;
  final _selection = <String, CatalogItem>{};
  CatalogFilter _advanced = CatalogFilter();
  int _contentRevision = 0, _progressRevision = 0, _cacheRevision = 0;
  void _repositoryChanged() {
    if (!mounted) return;
    if (_contentRevision != widget.repository.contentRevision ||
        _cacheRevision != widget.repository.cacheRevision) {
      _contentRevision = widget.repository.contentRevision;
      _cacheRevision = widget.repository.cacheRevision;
      _load(reset: true);
    } else if (_progressRevision != widget.repository.progressRevision) {
      _progressRevision = widget.repository.progressRevision;
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _contentRevision = widget.repository.contentRevision;
    _progressRevision = widget.repository.progressRevision;
    widget.repository.catalogChanges.addListener(_repositoryChanged);
    if (widget.kind == 'readlists' || widget.kind == 'collections') {
      _sort = 'name,asc';
    }
    if (widget.condition?['seriesId'] != null) {
      _sort = 'metadata.numberSort,asc';
    }
    if (widget.initialSort != null) _sort = widget.initialSort!;
    _advanced = widget.initialFilter ?? CatalogFilter();
    _query = widget.initialSearch ?? '';
    _search.text = _query;
    _selecting = widget.onPicked != null;
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600 &&
          !_last &&
          !_busy &&
          _error == null) {
        _load();
      }
    });
    _load(reset: true);
  }

  @override
  void didUpdateWidget(CatalogPageView old) {
    super.didUpdateWidget(old);
    if (old.repository != widget.repository) {
      old.repository.catalogChanges.removeListener(_repositoryChanged);
      widget.repository.catalogChanges.addListener(_repositoryChanged);
    }
    if (old.repository != widget.repository ||
        old.kind != widget.kind ||
        jsonEncode(old.condition) != jsonEncode(widget.condition) ||
        old.path != widget.path) {
      _load(reset: true);
    }
  }

  @override
  void dispose() {
    widget.repository.catalogChanges.removeListener(_repositoryChanged);
    _generation++;
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({
    bool reset = false,
    bool clear = false,
    bool force = false,
  }) async {
    final count = reset && !clear ? _page.clamp(1, 1000000) : 1;
    final start = reset ? 0 : _page;
    if (reset) {
      _generation++;
      _last = false;
      if (clear) {
        _items = [];
        _page = 0;
      }
    }
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      Json? condition = combineConditions([
        widget.condition,
        _advanced.condition(widget.kind),
      ]);
      if (_readStatus.isNotEmpty) {
        final filter = {
          'readStatus': {'operator': 'is', 'value': _readStatus},
        };
        condition = condition == null
            ? filter
            : {
                'allOf': [condition, filter],
              };
      }
      final results = await Future.wait(
        List.generate(
          count,
          (offset) => widget.repository.catalog(
            widget.kind,
            page: start + offset,
            search: _query,
            condition: condition,
            sort: _sort,
            path: widget.path,
            libraryId: widget.libraryId,
            force: force,
          ),
        ),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        if (reset) _items = [];
        final known = _items.map((v) => v.id).toSet();
        _items.addAll(
          results
              .expand((result) => result.items)
              .where((v) => known.add(v.id))
              .map(
                (v) =>
                    CatalogItem(v.kind, v.json, readListId: widget.readListId),
              ),
        );
        _last = results.last.last || results.last.items.isEmpty;
        _page = start + count;
        if (widget.kind == 'readlists' || widget.kind == 'collections') {
          final pinned = CatalogTools(widget.repository).pinned(widget.kind);
          final order = {
            for (var i = 0; i < _items.length; i++) _items[i].id: i,
          };
          _items.sort((a, b) {
            final first = pinned.indexOf(a.id), second = pinned.indexOf(b.id);
            if (first >= 0 && second >= 0) return first.compareTo(second);
            if (first >= 0) return -1;
            if (second >= 0) return 1;
            return order[a.id]!.compareTo(order[b.id]!);
          });
        }
      });
    } catch (e) {
      if (mounted && generation == _generation) setState(() => _error = e);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  void _choose(CatalogItem item) {
    if (widget.onItemPicked != null) {
      widget.onItemPicked!(item);
      return;
    }
    if (!_selecting) {
      openItem(context, widget.repository, item);
      return;
    }
    setState(() {
      if (_selection.remove(item.id) == null) _selection[item.id] = item;
    });
  }

  void _begin(CatalogItem item) {
    if (widget.onItemPicked != null) {
      widget.onItemPicked!(item);
      return;
    }
    setState(() {
      _selecting = true;
      _selection[item.id] = item;
    });
  }

  Future<void> _filters() async {
    final result = await Navigator.push<FilterSelection>(
      context,
      MaterialPageRoute(
        builder: (_) => FilterPage(
          repository: widget.repository,
          kind: widget.kind,
          initial: _readStatus.isEmpty
              ? _advanced
              : CatalogFilter(
                  entries: [
                    if (_advanced.entries.isNotEmpty) _advanced.toJson(),
                    {
                      'field': 'readStatus',
                      'operator': 'is',
                      'value': _readStatus,
                    },
                  ],
                ),
          search: _query,
          sort: _sort,
        ),
      ),
    );
    if (result == null || !mounted) return;
    _advanced = result.filter;
    _query = result.search;
    _sort = result.sort;
    _search.text = _query;
    _readStatus = '';
    _load(reset: true, clear: true);
  }

  Future<void> _saved() async {
    final values = CatalogTools(widget.repository).presets
        .where((p) => p.kind == widget.kind)
        .toList();
    if (values.isEmpty) {
      _filters();
      return;
    }
    final selected = await chooseValue(
      context,
      title: 'Saved Filters',
      selected: '',
      choices: {for (final p in values) p.id: p.name},
      translateChoices: false,
      searchable: true,
    );
    if (selected == null || !mounted) return;
    final preset = values.firstWhere((p) => p.id == selected);
    _advanced = preset.filter;
    _readStatus = '';
    _query = preset.search;
    _sort = preset.sort;
    _search.text = _query;
    _load(reset: true, clear: true);
  }

  Future<void> _createList() async {
    final tools = CatalogTools(widget.repository);
    final values = await pickCatalogItems(
      context,
      widget.repository,
      widget.kind == 'readlists' ? 'books' : 'series',
    );
    if (values == null || values.isEmpty || !mounted) return;
    final name = await askName(context, 'Create New List');
    if (name == null) return;
    try {
      await widget.repository.api.request(
        '/api/v1/${widget.kind}',
        method: 'POST',
        body: {
          'name': name,
          'ordered': true,
          if (widget.kind == 'readlists') 'summary': '',
          widget.kind == 'readlists' ? 'bookIds' : 'seriesIds': values
              .map((v) => v.id)
              .toList(),
        },
      );
      tools.repository.refreshContent();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _action(String action) async {
    if (_acting || _selection.isEmpty) return;
    setState(() => _acting = true);
    final items = _selection.values.toList();
    final tools = CatalogTools(widget.repository);
    try {
      if (action == 'read' || action == 'unread') {
        await tools.batchProgress(items, action == 'read');
      }
      if (action == 'download') await tools.batchDownload(items);
      if (action == 'add' && mounted) {
        await addEntriesToList(
          context,
          widget.repository,
          widget.kind == 'books' ? 'readlists' : 'collections',
          items.map((v) => v.id).toList(),
        );
      }
      if (action == 'metadata' && mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MetadataEditor(
              repository: widget.repository,
              item: items.first,
              items: items,
            ),
          ),
        );
      }
      if (action == 'pin') {
        for (final item in items) {
          tools.pin(widget.kind, item.id);
        }
      }
      if (mounted) {
        setState(() {
          _selection.clear();
          _selecting = widget.onPicked != null;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (_selecting)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: tr(context, 'Cancel'),
                onPressed: _acting
                    ? null
                    : () => setState(() {
                        _selection.clear();
                        if (widget.onPicked == null) _selecting = false;
                      }),
                icon: const Icon(CupertinoIcons.xmark),
              ),
              Expanded(
                child: Text('${_selection.length} ${tr(context, 'Selected')}'),
              ),
              IconButton(
                tooltip: tr(context, 'Select Loaded Items'),
                onPressed: _acting
                    ? null
                    : () => setState(
                        () => _selection.addAll({
                          for (final item in _items) item.id: item,
                        }),
                      ),
                icon: const Icon(CupertinoIcons.checkmark_square),
              ),
              if (widget.onPicked != null)
                IconButton(
                  tooltip: tr(context, 'Done'),
                  onPressed: () => widget.onPicked!(_selection.values.toList()),
                  icon: const Icon(CupertinoIcons.check_mark),
                )
              else
                PopupMenuButton<String>(
                  enabled: !_acting && _selection.isNotEmpty,
                  onSelected: _action,
                  itemBuilder: (_) => [
                    if (widget.kind == 'books' || widget.kind == 'series') ...[
                      PopupMenuItem(
                        value: 'read',
                        child: Text(tr(context, 'Mark as Read')),
                      ),
                      PopupMenuItem(
                        value: 'unread',
                        child: Text(tr(context, 'Mark as Unread')),
                      ),
                      PopupMenuItem(
                        value: 'download',
                        child: Text(tr(context, 'Download')),
                      ),
                      if (widget.repository.profile.admin)
                        PopupMenuItem(
                          value: 'add',
                          child: Text(tr(context, 'Add to List')),
                        ),
                      if (widget.repository.profile.admin)
                        PopupMenuItem(
                          value: 'metadata',
                          child: Text(tr(context, 'Edit Metadata')),
                        ),
                    ] else
                      PopupMenuItem(
                        value: 'pin',
                        child: Text(tr(context, 'Pin / Unpin')),
                      ),
                  ],
                ),
              if (_acting)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            if (widget.searchEnabled)
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    hintText: tr(context, 'Search'),
                    prefixIcon: const Icon(CupertinoIcons.search),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _search.clear();
                              _query = '';
                              _load(reset: true);
                            },
                            icon: const Icon(
                              CupertinoIcons.clear_circled_solid,
                            ),
                          ),
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (v) {
                    _query = v.trim();
                    _load(reset: true, clear: true);
                  },
                ),
              ),
            if (_canFilter ||
                widget.kind == 'readlists' ||
                widget.kind == 'collections')
              PopupMenuButton<String>(
                tooltip: tr(context, 'Sort'),
                icon: const Icon(CupertinoIcons.arrow_up_arrow_down),
                onSelected: (v) {
                  _sort = v == '__direction__'
                      ? _sort
                            .split('|')
                            .map(
                              (part) => part.endsWith(',desc')
                                  ? '${part.substring(0, part.length - 5)},asc'
                                  : '${part.substring(0, part.lastIndexOf(','))},desc',
                            )
                            .join('|')
                      : v;
                  _load(reset: true, clear: true);
                },
                itemBuilder: (_) => [
                  for (final choice
                      in (widget.kind == 'collections' ||
                                  widget.kind == 'readlists'
                              ? {'name,asc': 'Title', 'name,desc': 'Descending'}
                              : {
                                  'metadata.titleSort,asc': 'Title',
                                  if (widget.kind == 'books')
                                    'metadata.numberSort,asc': 'Number',
                                  'created,desc': 'Recently Added',
                                  'lastModified,desc': 'Recently Updated',
                                  if (widget.kind == 'books') ...{
                                    'series,asc|metadata.numberSort,asc':
                                        'bookSort.series',
                                    'metadata.releaseDate,desc':
                                        'bookSort.releaseDate',
                                    'readProgress.readDate,desc':
                                        'bookSort.dateRead',
                                    'fileSize,desc': 'bookSort.fileSize',
                                    'name,asc': 'bookSort.fileName',
                                    'media.pagesCount,desc':
                                        'bookSort.pageCount',
                                  } else ...{
                                    'booksMetadata.releaseDate,desc':
                                        'series.sortField.releaseDate',
                                    'fileLastModified,desc':
                                        'series.sortField.dateRead',
                                    'metadata.title,asc':
                                        'series.sortField.folderName',
                                    'booksCount,desc':
                                        'series.sortField.booksCount',
                                    'random,asc': 'series.sortField.random',
                                  },
                                })
                          .entries)
                    CheckedPopupMenuItem(
                      value: choice.key,
                      checked:
                          sortFields(widget.kind, _sort) ==
                          sortFields(widget.kind, choice.key),
                      child: Text(tr(context, choice.value)),
                    ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: '__direction__',
                    enabled: !_sort.startsWith('random,'),
                    child: Text(
                      tr(
                        context,
                        _sort.endsWith(',desc') ? 'Ascending' : 'Descending',
                      ),
                    ),
                  ),
                ],
              ),
            if ((widget.kind == 'books' || widget.kind == 'series') &&
                (_canFilter || widget.readListId != null))
              PopupMenuButton<String>(
                tooltip: tr(context, 'Filter'),
                icon: Icon(
                  _readStatus.isEmpty && _advanced.entries.isEmpty
                      ? CupertinoIcons.line_horizontal_3_decrease
                      : CupertinoIcons.line_horizontal_3_decrease_circle_fill,
                ),
                onSelected: (v) {
                  if (v == '__advanced__') {
                    _filters();
                    return;
                  }
                  if (v == '__saved__') {
                    _saved();
                    return;
                  }
                  _readStatus = v;
                  _load(reset: true, clear: true);
                },
                itemBuilder: (_) => [
                  if (_canFilter) ...[
                    PopupMenuItem(
                      value: '__advanced__',
                      child: Text(tr(context, 'Advanced Filters')),
                    ),
                    PopupMenuItem(
                      value: '__saved__',
                      child: Text(tr(context, 'Saved Filters')),
                    ),
                  ],
                  for (final e in {
                    '': 'All',
                    'UNREAD': 'Unread',
                    'IN_PROGRESS': 'In Progress',
                    'READ': 'Read',
                  }.entries)
                    CheckedPopupMenuItem(
                      value: e.key,
                      checked: _readStatus == e.key,
                      child: Text(tr(context, e.value)),
                    ),
                ],
              ),
            if ((widget.kind == 'readlists' || widget.kind == 'collections') &&
                widget.repository.profile.admin &&
                !_selecting)
              IconButton(
                tooltip: tr(context, 'Create New List'),
                onPressed: _createList,
                icon: const Icon(CupertinoIcons.add),
              ),
            IconButton(
              tooltip: tr(context, 'Layout'),
              onPressed: () => setState(() => _list = !_list),
              icon: Icon(
                _list
                    ? CupertinoIcons.square_grid_2x2
                    : CupertinoIcons.list_bullet,
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: _items.isEmpty && _busy
            ? const Center(child: CircularProgressIndicator.adaptive())
            : _items.isEmpty && _error != null
            ? FailureView(error: _error!, retry: () => _load(reset: true))
            : _items.isEmpty
            ? RefreshIndicator(
                onRefresh: () => _load(reset: true, force: true),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(height: 120),
                    EmptyView(
                      title: 'No Results',
                      message: 'Try another search or add content to your Komga library.',
                    ),
                  ],
                ),
              )
            : RefreshIndicator(
                onRefresh: () => _load(reset: true, force: true),
                child: CustomScrollView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    if (_list)
                      SliverList.builder(
                        itemCount: _items.length,
                        itemBuilder: (context, i) {
                          final item = _items[i];
                          return ListTile(
                            selected: _selection.containsKey(item.id),
                            onLongPress: () => _begin(item),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 6,
                            ),
                            leading: SizedBox(
                              width: 38,
                              height: 56,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Cover(
                                  repository: widget.repository,
                                  path: item.thumbnail,
                                ),
                              ),
                            ),
                            title: Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(item.subtitle),
                            trailing: _selecting
                                ? Checkbox(
                                    value: _selection.containsKey(item.id),
                                    onChanged: (_) => _choose(item),
                                  )
                                : const Icon(
                                    CupertinoIcons.chevron_right,
                                    size: 16,
                                  ),
                            onTap: () => _choose(item),
                          );
                        },
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.all(16),
                        sliver: SliverLayoutBuilder(
                          builder: (context, constraints) {
                            final width = constraints.crossAxisExtent > 800
                                ? 128.0
                                : 160.0;
                            final count =
                                (constraints.crossAxisExtent / (width + 16))
                                    .floor()
                                    .clamp(2, 12);
                            return SliverGrid.builder(
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: count,
                                    crossAxisSpacing: 16,
                                    mainAxisSpacing: 20,
                                    childAspectRatio: .53,
                                  ),
                              itemCount: _items.length,
                              itemBuilder: (context, index) => Stack(
                                fit: StackFit.expand,
                                children: [
                                  BookCard(
                                    repository: widget.repository,
                                    item: _items[index],
                                    onTap: () => _choose(_items[index]),
                                    onLongPress: () => _begin(_items[index]),
                                  ),
                                  if (_selecting)
                                    Positioned(
                                      top: 4,
                                      right: 4,
                                      child: Material(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surface,
                                        shape: const CircleBorder(),
                                        child: Checkbox(
                                          value: _selection.containsKey(
                                            _items[index].id,
                                          ),
                                          onChanged: (_) =>
                                              _choose(_items[index]),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    if (_busy)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(
                            child: CircularProgressIndicator.adaptive(),
                          ),
                        ),
                      ),
                    if (_error != null)
                      SliverToBoxAdapter(
                        child: FailureView(error: _error!, retry: _load),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 28)),
                  ],
                ),
              ),
      ),
    ],
  );
}

class BookCard extends StatelessWidget {
  const BookCard({
    super.key,
    required this.repository,
    required this.item,
    this.onTap,
    this.onLongPress,
  });
  final Repository repository;
  final CatalogItem item;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: item.title,
    child: InkWell(
      onTap: onTap ?? () => openItem(context, repository, item),
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .16),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox.expand(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Cover(repository: repository, path: item.thumbnail),
                      if (item.kind == 'books' &&
                          repository.overlay(item.book).completed)
                        const Positioned(
                          right: 6,
                          top: 6,
                          child: CircleAvatar(
                            radius: 10,
                            backgroundColor: Colors.white,
                            child: Icon(
                              CupertinoIcons.check_mark,
                              size: 12,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      if (item.kind == 'series' &&
                          integer(item.json['booksUnreadCount']) > 0)
                        Positioned(
                          right: 6,
                          top: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${item.json['booksUnreadCount']}',
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context).colorScheme.onPrimary,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 3),
          Text(
            item.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
          ),
          if (item.kind == 'books' &&
              repository.overlay(item.book).page > 0) ...[
            const SizedBox(height: 5),
            LinearProgressIndicator(
              value: repository.overlay(item.book).fraction,
              minHeight: 2,
            ),
          ],
        ],
      ),
    ),
  );
}
