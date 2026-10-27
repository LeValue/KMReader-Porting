import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'detail_page.dart';

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
  });
  final Repository repository;
  final String kind;
  final String? title, path;
  final Json? condition;
  final bool searchEnabled;
  final String? readListId;
  final String? libraryId, initialSort;
  @override
  State<CatalogPageView> createState() => _CatalogPageViewState();
}

class _CatalogPageViewState extends State<CatalogPageView> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  List<CatalogItem> _items = [];
  bool _busy = false, _last = false;
  int _page = 0;
  int _generation = 0;
  Object? _error;
  String _query = '', _sort = 'metadata.titleSort,asc', _readStatus = '';
  bool _list = false;
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
      Json? condition = widget.condition;
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
      });
    } catch (e) {
      if (mounted && generation == _generation) setState(() => _error = e);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
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
            PopupMenuButton<String>(
              tooltip: tr(context, 'Sort'),
              icon: const Icon(CupertinoIcons.arrow_up_arrow_down),
              onSelected: (v) {
                _sort = v;
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
                              })
                        .entries)
                  CheckedPopupMenuItem(
                    value: choice.key,
                    checked: _sort == choice.key,
                    child: Text(tr(context, choice.value)),
                  ),
              ],
            ),
            if (widget.kind == 'books' || widget.kind == 'series')
              PopupMenuButton<String>(
                tooltip: tr(context, 'Filter'),
                icon: Icon(
                  _readStatus.isEmpty
                      ? CupertinoIcons.line_horizontal_3_decrease
                      : CupertinoIcons.line_horizontal_3_decrease_circle_fill,
                ),
                onSelected: (v) {
                  _readStatus = v;
                  _load(reset: true, clear: true);
                },
                itemBuilder: (_) => [
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
                            trailing: const Icon(
                              CupertinoIcons.chevron_right,
                              size: 16,
                            ),
                            onTap: () =>
                                openItem(context, widget.repository, item),
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
                              itemBuilder: (context, index) => BookCard(
                                repository: widget.repository,
                                item: _items[index],
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
  });
  final Repository repository;
  final CatalogItem item;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: item.title,
    child: InkWell(
      onTap: onTap ?? () => openItem(context, repository, item),
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
