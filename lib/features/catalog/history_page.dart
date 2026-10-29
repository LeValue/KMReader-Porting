import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/models.dart';
import '../../core/api.dart';
import '../../core/repository.dart';
import '../../core/reading_stats.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'catalog_page.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.repository});
  final Repository repository;
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: repository.profile.admin ? 3 : 2,
    child: Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'History')),
        bottom: TabBar(
          isScrollable: true,
          tabs: [
            Tab(text: tr(context, 'Reading History')),
            Tab(text: tr(context, 'Statistics')),
            if (repository.profile.admin)
              Tab(text: tr(context, 'Server Events')),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          CatalogPageView(
            repository: repository,
            kind: 'books',
            initialSort: 'readProgress.readDate,desc',
            condition: {
              'readStatus': {'operator': 'isNot', 'value': 'UNREAD'},
            },
          ),
          ReadingStatsPage(repository: repository),
          if (repository.profile.admin)
            ServerEventsPage(repository: repository),
        ],
      ),
    ),
  );
}

class ReadingStatsPage extends StatefulWidget {
  const ReadingStatsPage({super.key, required this.repository});
  final Repository repository;
  @override
  State<ReadingStatsPage> createState() => _ReadingStatsPageState();
}

class _ReadingStatsPageState extends State<ReadingStatsPage> {
  late Future<Json> _future;
  String? _library;
  int _days = 365;
  @override
  void initState() {
    super.initState();
    _future = ReadingStats(widget.repository).load();
  }

  Future<void> _refresh() async {
    setState(
      () => _future = ReadingStats(widget.repository).load(libraryId: _library),
    );
    await _future;
  }

  Future<void> _scope() async {
    try {
      final libraries = (await widget.repository.get(
        '/api/v1/libraries',
        cacheFirst: true,
      ) as List).map(object);
      if (!mounted) return;
      final id = await chooseValue(
        context,
        title: 'Library',
        selected: _library ?? '',
        choices: {
          '': tr(context, 'All Libraries'),
          for (final l in libraries) text(l['id']): text(l['name']),
        },
        translateChoices: false,
        searchable: true,
      );
      if (id == null || !mounted) return;
      _library = id.isEmpty ? null : id;
      await _refresh();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _rank(String title, List<dynamic> values, {int limit = 12}) {
    final items = values
        .map(object)
        .where((v) => (v['value'] as num? ?? 0) > 0)
        .take(limit)
        .toList();
    if (items.isEmpty) return const SizedBox.shrink();
    final maximum = items
        .map((v) => (v['value'] as num).toDouble())
        .reduce((a, b) => a > b ? a : b);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr(context, title),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            for (final row in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(text(row['name']))),
                        Text(
                          NumberFormat.compact(
                            locale: Localizations.localeOf(context)
                                .toLanguageTag(),
                          ).format(row['value']),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: (row['value'] as num) / maximum,
                      minHeight: 5,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _heatmap(Json data) {
    final values = <String, num>{
      for (final row in (data['readingTimeSeries'] as List? ?? []).map(object))
        text(row['date'], text(row['name'])).split('T').first:
            (row['value'] as num? ?? 0),
    };
    final now = DateUtils.dateOnly(DateTime.now());
    final maximum = values.values.fold<num>(0, (a, b) => a > b ? a : b);
    final dates = [
      for (var i = _days - 1; i >= 0; i--)
        DateTime(now.year, now.month, now.day - i),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr(context, 'Pages Read'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                DropdownButton<int>(
                  value: _days,
                  items: [
                    for (final n in [30, 90, 365])
                      DropdownMenuItem(
                        value: n,
                        child: Text('$n ${tr(context, 'Days')}'),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _days = v);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 3,
              runSpacing: 3,
              children: [
                for (final day in dates)
                  Builder(
                    builder: (context) {
                      final key = DateFormat('yyyy-MM-dd').format(day);
                      final count = values[key] ?? 0;
                      return Tooltip(
                        message:
                            '${DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(day)}: $count ${tr(context, 'pages')}',
                        child: Semantics(
                          label: '$key: $count',
                          child: Container(
                            width: 13,
                            height: 13,
                            decoration: BoxDecoration(
                              color: count == 0
                                  ? Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest
                                  : Theme.of(context).colorScheme.primary
                                        .withValues(
                                          alpha:
                                              .25 +
                                              .75 *
                                                  (maximum > 0
                                                      ? count / maximum
                                                      : 0),
                                        ),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Json>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return FailureView(error: snapshot.error!, retry: _refresh);
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator.adaptive());
      }
      final data = snapshot.data!, summary = object(data['summary']);
      final metrics = <String, dynamic>{
        'Total Books': summary['totalBooks'],
        'Started': summary['booksStartedReading'],
        'Completed': summary['booksCompletedReading'],
        'Pages Read': summary['totalPagesRead'],
        'Average Pages per Book': summary['averagePagesPerBook'],
        'Reading Days': summary['readingDays'],
        if (summary['currentStreakDays'] != null)
          'Current Streak': summary['currentStreakDays'],
        if (summary['longestStreakDays'] != null)
          'Longest Streak': summary['longestStreakDays'],
      };
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr(
                      context,
                      data['source'] == 'server'
                          ? 'Server Statistics'
                          : 'Reading Statistics',
                    ),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: tr(context, 'Library'),
                  onPressed: _scope,
                  icon: const Icon(CupertinoIcons.slider_horizontal_3),
                ),
                IconButton(
                  tooltip: tr(context, 'Refresh'),
                  onPressed: _refresh,
                  icon: const Icon(CupertinoIcons.arrow_clockwise),
                ),
              ],
            ),
            Text(
              '${tr(context, data['complete'] == true ? 'Updated' : 'Cached Books Only')}: ${text(data['generatedAt']).split('.').first}${data['offline'] == true ? ' · ${tr(context, 'Offline Mode')}' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final metric in metrics.entries)
                  SizedBox(
                    width: 155,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              NumberFormat.decimalPattern(
                                Localizations.localeOf(context).toLanguageTag(),
                              ).format(metric.value ?? 0),
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                            Text(tr(context, metric.key)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            _heatmap(data),
            _rank('Read Status', [
              for (final row in (data['statusDistribution'] as List? ?? []).map(
                object,
              ))
                {
                  ...row,
                  'name': tr(
                    context,
                    {
                          'read': 'Read',
                          'inProgress': 'In Progress',
                          'unread': 'Unread',
                        }[row['name']] ??
                        text(row['name']),
                  ),
                },
            ]),
            _rank('Reading by Day', [
              for (var i = 0; i < 7; i++)
                {
                  'name': DateFormat.EEEE(
                    Localizations.localeOf(context).toLanguageTag(),
                  ).format(DateTime(2026, 10, 25 + i)),
                  'value':
                      (data['weekdayDistribution'] as List? ?? [])
                          .elementAtOrNull(i) ??
                      0,
                },
            ]),
            _rank('Reading by Hour', [
              for (var i = 0; i < 24; i++)
                {
                  'name': '${i.toString().padLeft(2, '0')}:00',
                  'value':
                      (data['hourlyDistribution'] as List? ?? [])
                          .elementAtOrNull(i) ??
                      0,
                },
            ], limit: 24),
            _rank('Top Authors', data['topAuthors'] as List? ?? []),
            _rank('Top Genres', data['topGenres'] as List? ?? []),
            _rank('Top Tags', data['topTags'] as List? ?? []),
          ],
        ),
      );
    },
  );
}

class AuthenticationActivityPage extends StatelessWidget {
  const AuthenticationActivityPage({super.key, required this.repository});
  final Repository repository;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'Authentication Activity'))),
    body: SafeArea(
      top: false,
      child: ServerEventsPage(repository: repository, authentication: true),
    ),
  );
}

class ServerEventsPage extends StatefulWidget {
  const ServerEventsPage({
    super.key,
    required this.repository,
    this.authentication = false,
  });
  final Repository repository;
  final bool authentication;
  @override
  State<ServerEventsPage> createState() => _ServerEventsPageState();
}

class _ServerEventsPageState extends State<ServerEventsPage> {
  final _events = <Json>[];
  final _scroll = ScrollController();
  int _page = 0, _generation = 0;
  bool _loading = false, _last = false;
  bool _retryReset = false;
  Object? _error;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_more);
    _load();
  }

  void _more() {
    if (_error != null) return;
    if (_scroll.hasClients && _scroll.position.extentAfter < 500) _load();
  }

  @override
  void dispose() {
    _generation++;
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (!reset && (_loading || _last)) return;
    if (reset) {
      _generation++;
      _page = 0;
      _last = false;
    }
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = object(
        await widget.repository.get(
          widget.authentication
              ? '/api/v2/users/me/authentication-activity'
              : '/api/v1/history',
          query: {
            'page': _page,
            'size': widget.authentication ? 20 : 50,
            if (!widget.authentication) 'sort': 'timestamp,desc',
          },
        ),
      );
      if (!mounted || generation != _generation) return;
      if (data['content'] is! List) {
        throw const ApiFailure('The server returned an unexpected response.');
      }
      setState(() {
        if (reset) _events.clear();
        _events.addAll((data['content'] as List? ?? []).map(object));
        _last =
            data['last'] == true || (data['content'] as List? ?? []).isEmpty;
        _page++;
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = e;
          _retryReset = reset;
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () => _load(reset: true),
    child: ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _events.length + 1,
      itemBuilder: (context, index) {
        if (index == _events.length) {
          if (_error != null) {
            return FailureView(
              error: _error!,
              retry: () => _load(reset: _retryReset),
            );
          }
          if (_loading) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator.adaptive()),
            );
          }
          if (!_last) {
            return Center(
              child: TextButton(
                onPressed: _load,
                child: Text(tr(context, 'Load More')),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                tr(
                  context,
                  _events.isEmpty ? 'No Results' : 'All Events Loaded',
                ),
              ),
            ),
          );
        }
        final event = _events[index];
        if (widget.authentication) {
          final date = DateTime.tryParse(text(event['dateTime']));
          return ExpansionTile(
            leading: Icon(
              event['success'] == true
                  ? Icons.check_circle_outline
                  : Icons.error_outline,
              color: event['success'] == true
                  ? Theme.of(context).colorScheme.secondary
                  : Theme.of(context).colorScheme.error,
            ),
            title: Text(
              text(
                event['source'],
                tr(context, event['success'] == true ? 'Success' : 'Failed'),
              ),
            ),
            subtitle: Text(
              date == null
                  ? text(event['dateTime'])
                  : DateFormat.yMd(
                      Localizations.localeOf(context).toLanguageTag(),
                    ).add_Hms().format(date.toLocal()),
            ),
            children: [
              for (final entry in {
                'apiKeyComment': 'API Key',
                'userAgent': 'User Agent',
                'ip': 'IP Address',
                'error': 'Error',
              }.entries)
                if (event[entry.key] != null &&
                    text(event[entry.key]).isNotEmpty)
                  ListTile(
                    title: Text(tr(context, entry.value)),
                    subtitle: SelectableText(text(event[entry.key])),
                  ),
            ],
          );
        }
        return ExpansionTile(
          leading: const Icon(CupertinoIcons.clock),
          title: Text(
            tr(
              context,
              text(event['type']).isEmpty
                  ? 'History'
                  : 'history.event.${text(event['type'])[0].toLowerCase()}${text(event['type']).substring(1)}',
            ),
          ),
          subtitle: Text(text(event['timestamp'])),
          children: [
            for (final entry in {
              ...object(event['properties']),
              if (event['bookId'] != null) 'bookId': event['bookId'],
              if (event['seriesId'] != null) 'seriesId': event['seriesId'],
            }.entries)
              ListTile(
                title: Text(entry.key),
                subtitle: SelectableText('${entry.value}'),
              ),
          ],
        );
      },
    ),
  );
}
