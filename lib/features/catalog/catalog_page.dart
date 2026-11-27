import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/browse_preferences.dart';
import '../../ui/catalog_card.dart';
import '../../core/catalog_tools.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'detail_page.dart';
import 'filter_page.dart';
import 'list_actions.dart';
import 'metadata_editor.dart';
import '../../ui/wheel_scroll.dart';

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

class CatalogSearchPage extends StatefulWidget {
  const CatalogSearchPage({super.key, required this.repository});

  final Repository repository;

  @override
  State<CatalogSearchPage> createState() => _CatalogSearchPageState();
}

class _CatalogSearchPageState extends State<CatalogSearchPage> {
  final _search = TextEditingController();
  var _kind = 'books';
  var _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _submit() {
    if (_query != _search.text.trim()) {
      setState(() => _query = _search.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'Search'))),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            autofocus: true,
            controller: _search,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: tr(context, 'Search your library'),
              suffixIcon: IconButton(
                onPressed: _submit,
                icon: const Icon(CupertinoIcons.search),
                tooltip: tr(context, 'Search'),
              ),
            ),
          ),
        ),
        if (widget.repository.supportsSeries)
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'books', label: Text(tr(context, 'Books'))),
              ButtonSegment(
                value: 'series',
                label: Text(tr(context, 'Series')),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: (selection) =>
                setState(() => _kind = selection.single),
          ),
        if (_query.isNotEmpty)
          Expanded(
            child: CatalogPageView(
              key: ValueKey((_kind, _query)),
              repository: widget.repository,
              kind: _kind,
              preferenceScope: 'search',
              searchEnabled: false,
              initialSearch: _query,
            ),
          ),
      ],
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
    this.libraryIds,
    this.initialSort,
    this.onPicked,
    this.initialFilter,
    this.initialSearch,
    this.onItemPicked,
    this.preferenceScope,
    this.header,
  });
  final Repository repository;
  final String kind;
  final String? title, path;
  final Json? condition;
  final bool searchEnabled;
  final String? readListId;
  final String? libraryId, initialSort;
  final List<String>? libraryIds;
  final ValueChanged<List<CatalogItem>>? onPicked;
  final CatalogFilter? initialFilter;
  final String? initialSearch;
  final ValueChanged<CatalogItem>? onItemPicked;
  final String? preferenceScope;
  final Widget? header;
  @override
  State<CatalogPageView> createState() => _CatalogPageViewState();
}

class _CatalogPageViewState extends State<CatalogPageView> {
  bool get _canFilter =>
      widget.path == null || widget.path!.startsWith('/api/v1/smart-lists/');
  final _scroll = AppScrollController();
  final _search = TextEditingController();
  List<CatalogItem> _items = [];
  bool _busy = false, _last = false;
  int _page = 0;
  int _generation = 0;
  Object? _error;
  String _query = '', _sort = 'metadata.titleSort,asc', _readStatus = '';
  bool _list = false;
  bool _selecting = false, _acting = false;
  late bool _offline;
  final _selection = <String, CatalogItem>{};
  CatalogFilter _advanced = CatalogFilter();
  int _contentRevision = 0, _progressRevision = 0, _cacheRevision = 0;
  late bool _ignoresSearchFilters;
  String? get _preferenceKey {
    final scope = widget.preferenceScope;
    return scope == null
        ? null
        : 'catalogView:${widget.repository.profile.id}:$scope:${widget.kind}';
  }

  Json get _preferences {
    final key = _preferenceKey;
    return key == null
        ? {}
        : object(widget.repository.store.setting<dynamic>(key));
  }

  String get _defaultSort =>
      widget.initialSort ??
      (widget.kind == 'readlists' || widget.kind == 'collections'
          ? 'name,asc'
          : widget.condition?['seriesId'] != null
          ? 'metadata.numberSort,asc'
          : 'metadata.titleSort,asc');

  String _preferredSort(Json preferences) {
    final online = _availableSort(
      text(preferences['sort'], _defaultSort),
      offline: false,
    );
    return _offline ? text(preferences['offlineSort'], online) : online;
  }

  String _availableSort(String value, {required bool offline}) =>
      !offline && value.startsWith('downloadAt,') ? _defaultSort : value;

  void _restorePreferences() {
    final preferences = _preferences;
    _sort = _preferredSort(preferences);
    _advanced =
        widget.initialFilter ??
        CatalogFilter.fromJson(object(preferences['filter']));
    _readStatus = text(preferences['readStatus']);
    _list = preferences['list'] == true;
  }

  void _savePreferences({bool sortChanged = false}) {
    final key = _preferenceKey;
    if (key == null) return;
    final values = _preferences;
    widget.repository.store.setSetting(key, {
      ...values,
      if (sortChanged) (_offline ? 'offlineSort' : 'sort'): _sort,
      'filter': _advanced.toJson(),
      'readStatus': _readStatus,
      'list': _list,
    });
  }

  void _browseChanged() {
    final ignores = widget.repository.browse[BrowseOption.ignoreSearchFilters];
    if (_ignoresSearchFilters != ignores && _query.isNotEmpty) {
      _ignoresSearchFilters = ignores;
      _load(reset: true, clear: true);
    } else {
      _ignoresSearchFilters = ignores;
      setState(() {});
    }
  }

  Json? get _effectiveCondition => combineConditions([
    widget.condition,
    if (!(_ignoresSearchFilters && _query.isNotEmpty)) ...[
      _advanced.condition(widget.kind),
      if (_readStatus.isNotEmpty)
        {
          'readStatus': {'operator': 'is', 'value': _readStatus},
        },
    ],
  ]);

  void _repositoryChanged() {
    if (!mounted) return;
    final offline = widget.repository.offline;
    if (_offline != offline) {
      _offline = offline;
      if (_preferenceKey != null) {
        _sort = _preferredSort(_preferences);
      } else if (!offline && _sort.startsWith('downloadAt,')) {
        _sort = _defaultSort;
      }
    }
    final progressChanged =
        _progressRevision != widget.repository.progressRevision;
    final refreshReading =
        offline &&
        progressChanged &&
        (_sort.startsWith('readProgress.readDate,') ||
            widget.path == '/api/v1/books/ondeck' ||
            jsonEncode(_effectiveCondition).contains('"readStatus"'));
    _progressRevision = widget.repository.progressRevision;
    if (refreshReading ||
        _contentRevision != widget.repository.contentRevision ||
        _cacheRevision != widget.repository.cacheRevision) {
      _contentRevision = widget.repository.contentRevision;
      _cacheRevision = widget.repository.cacheRevision;
      _load(reset: true);
    } else if (progressChanged) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _ignoresSearchFilters =
        widget.repository.browse[BrowseOption.ignoreSearchFilters];
    widget.repository.browse.addListener(_browseChanged);
    _contentRevision = widget.repository.contentRevision;
    _progressRevision = widget.repository.progressRevision;
    _offline = widget.repository.offline;
    widget.repository.catalogChanges.addListener(_repositoryChanged);
    _restorePreferences();
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
      old.repository.browse.removeListener(_browseChanged);
      widget.repository.browse.addListener(_browseChanged);
      _ignoresSearchFilters =
          widget.repository.browse[BrowseOption.ignoreSearchFilters];
      old.repository.catalogChanges.removeListener(_repositoryChanged);
      widget.repository.catalogChanges.addListener(_repositoryChanged);
      _offline = widget.repository.offline;
      _restorePreferences();
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
    widget.repository.browse.removeListener(_browseChanged);
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
      final condition = _effectiveCondition;
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
            libraryIds: widget.libraryIds,
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
    if (widget.searchEnabled) _query = result.search;
    _sort = _availableSort(result.sort, offline: _offline);
    _search.text = _query;
    _readStatus = '';
    _savePreferences(sortChanged: true);
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
    if (widget.searchEnabled) _query = preset.search;
    _sort = _availableSort(preset.sort, offline: _offline);
    _search.text = _query;
    _savePreferences(sortChanged: true);
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

  bool _selectingAll = false, _cancelSelection = false;
  Future<void> _selectAll() async {
    if (_acting) return;
    final repository = widget.repository;
    final generation = _generation;
    setState(() {
      _acting = true;
      _selectingAll = true;
      _cancelSelection = false;
    });
    try {
      final condition = _effectiveCondition;
      final found = <String, CatalogItem>{};
      final sort = _sort.startsWith('random,')
          ? 'metadata.titleSort,asc'
          : _sort;
      for (var page = 0; ; page++) {
        if (!mounted ||
            repository.closed ||
            _cancelSelection ||
            generation != _generation) {
          return;
        }
        final chunk = await repository.catalog(
          widget.kind,
          path: widget.path,
          page: page,
          size: 200,
          libraryId: widget.libraryId,
          libraryIds: widget.libraryIds,
          search: _query,
          sort: sort,
          condition: condition,
        );
        if (!mounted ||
            repository.closed ||
            _cancelSelection ||
            generation != _generation) {
          return;
        }
        if (chunk.items.isEmpty && !chunk.last) {
          throw const ApiFailure(
            'The catalog changed during selection. Try again.',
          );
        }
        for (final item in chunk.items) {
          found[item.id] = CatalogItem(
            item.kind,
            item.json,
            readListId: widget.readListId,
          );
        }
        if (chunk.last) {
          if (found.length != chunk.total) {
            throw const ApiFailure(
              'The catalog changed during selection. Try again.',
            );
          }
          break;
        }
      }
      setState(() => _selection.addAll(found));
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) {
        setState(() {
          _acting = false;
          _selectingAll = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (widget.repository.offline &&
          !widget.repository.offlineMetadataComplete)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            tr(context, 'Cached Books Only'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      if (_selecting)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: tr(context, 'Cancel'),
                onPressed: _selectingAll
                    ? () => setState(() => _cancelSelection = true)
                    : _acting
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
              if (_selectingAll)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                PopupMenuButton<String>(
                  tooltip: tr(context, 'Select All'),
                  enabled: !_acting,
                  icon: const Icon(CupertinoIcons.checkmark_square),
                  onSelected: (value) {
                    if (value == 'all') {
                      _selectAll();
                    } else {
                      setState(
                        () => _selection.addAll({
                          for (final item in _items) item.id: item,
                        }),
                      );
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'all',
                      child: Text(tr(context, 'Select All Results')),
                    ),
                    PopupMenuItem(
                      value: 'loaded',
                      child: Text(tr(context, 'Select Loaded Items')),
                    ),
                  ],
                ),
              if (widget.onPicked != null)
                IconButton(
                  tooltip: tr(context, 'Done'),
                  onPressed: _acting
                      ? null
                      : () => widget.onPicked!(_selection.values.toList()),
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
                  _savePreferences(sortChanged: true);
                  _load(reset: true, clear: true);
                },
                itemBuilder: (_) => [
                  for (final choice
                      in (widget.kind == 'collections' ||
                                  widget.kind == 'readlists'
                              ? {'name,asc': 'Title'}
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
                                    if (_offline)
                                      'downloadAt,desc':
                                          'bookSort.downloadDate',
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
                                    if (_offline)
                                      'downloadAt,desc':
                                          'series.sortField.downloadDate',
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
                  _savePreferences();
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
              onPressed: () => setState(() {
                _list = !_list;
                _savePreferences();
              }),
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
        child: RefreshIndicator(
          onRefresh: () => _load(reset: true, force: true),
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (widget.header case final header?)
                SliverToBoxAdapter(child: header),
              if (_items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _busy
                      ? const Center(
                          child: CircularProgressIndicator.adaptive(),
                        )
                      : _error != null
                      ? FailureView(
                          error: _error!,
                          retry: () => _load(reset: true),
                        )
                      : const EmptyView(
                          title: 'No Results',
                          message: 'Try another search or add content to your Komga library.',
                        ),
                )
              else if (_list)
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
                          : const Icon(CupertinoIcons.chevron_right, size: 16),
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
                      final count = (constraints.crossAxisExtent / (width + 16))
                          .floor()
                          .clamp(2, 12);
                      return SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: count,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 20,
                          childAspectRatio:
                              widget.repository.browse.hidesText ||
                                  widget.repository.browse.overlaysText
                              ? .68
                              : .53,
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
                                  color: Theme.of(context).colorScheme.surface,
                                  shape: const CircleBorder(),
                                  child: Checkbox(
                                    value: _selection.containsKey(
                                      _items[index].id,
                                    ),
                                    onChanged: (_) => _choose(_items[index]),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              if (_busy && _items.isNotEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator.adaptive()),
                  ),
                ),
              if (_error != null && _items.isNotEmpty)
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
  final VoidCallback? onTap, onLongPress;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: repository.browse,
    builder: (context, _) {
      final book = item.kind == 'books' ? repository.overlay(item.book) : null;
      return Semantics(
        button: true,
        label: item.title,
        child: InkWell(
          onTap: onTap ?? () => openItem(context, repository, item),
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(8),
          child: CatalogCard(
            preferences: repository.browse,
            coverBuilder: (frame) => Cover(
              repository: repository,
              path: item.thumbnail,
              frameBuilder: (context, image, _, _) => frame(image),
              fit:
                  repository.browse[BrowseOption.preserveAspectRatio] &&
                      !repository.browse.overlaysText
                  ? BoxFit.contain
                  : BoxFit.cover,
            ),
            title: item.title,
            subtitle: book == null ? null : item.subtitle,
            detail: book == null
                ? '${item.subtitle} ${tr(context, item.kind == 'collections' ? 'Series' : 'Books')}'
                : book.pages > 0
                ? '${book.pageCountLabel} ${tr(context, 'Pages')}'
                : '',
            unread: book == null
                ? item.kind == 'series' &&
                      integer(item.json['booksReadCount']) == 0 &&
                      integer(item.json['booksInProgressCount']) == 0
                : !book.completed && book.page == 0,
            unreadCount: item.kind == 'series'
                ? integer(item.json['booksUnreadCount'])
                : 0,
            completed: book?.completed ?? false,
            progress: book?.fraction ?? 0,
          ),
        ),
      );
    },
  );
}
