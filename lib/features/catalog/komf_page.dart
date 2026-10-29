import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/external_links.dart';
import '../../core/komf.dart';
import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';

class KomfButton extends StatefulWidget {
  const KomfButton({super.key, required this.repository, required this.item});
  final Repository repository;
  final CatalogItem item;
  @override
  State<KomfButton> createState() => _KomfButtonState();
}

class _KomfButtonState extends State<KomfButton> {
  @override
  void initState() {
    super.initState();
    unawaited(
      widget.repository.komf.checkIntegration().catchError((Object _) => null),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.repository, widget.repository.komf]),
    builder: (context, _) =>
        !widget.repository.komf.connected || widget.repository.offline
        ? const SizedBox.shrink()
        : IconButton(
            tooltip: 'Komf',
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) =>
                    KomfPage(repository: widget.repository, item: widget.item),
              ),
            ),
          ),
  );
}

class KomfPage extends StatefulWidget {
  const KomfPage({super.key, required this.repository, required this.item});
  final Repository repository;
  final CatalogItem item;
  @override
  State<KomfPage> createState() => _KomfPageState();
}

class _KomfPageState extends State<KomfPage> {
  Future<Json> _series() async {
    final integration = await widget.repository.komf.checkIntegration();
    if (integration?['state'] != 'connected') {
      throw const ApiFailure('Komf is not connected to this server.');
    }
    final book = widget.item.kind == 'books'
        ? await widget.repository.book(widget.item.id)
        : null;
    final id = book?.seriesId ?? widget.item.id;
    if (id.isEmpty) {
      throw const ApiFailure(
        'This content is unavailable or the server does not support this feature.',
      );
    }
    final series = object(
      await widget.repository.get('/api/v1/series/${Uri.encodeComponent(id)}'),
    );
    if (series['id'] != id) {
      throw const ApiFailure('The server returned an unexpected response.');
    }
    final links = object(series['metadata'])['links'] as List? ?? [];
    return {
      ...series,
      'providerLinks': links.isEmpty && series['oneshot'] == true
          ? (book?.metadata['links'] as List? ?? [])
          : links,
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Komf · ${widget.item.title}')),
    body: SafeArea(
      top: false,
      child: AsyncPanel<Json>(
        load: _series,
        builder: (context, series) =>
            _KomfContent(repository: widget.repository, series: series),
      ),
    ),
  );
}

class _KomfContent extends StatefulWidget {
  const _KomfContent({required this.repository, required this.series});
  final Repository repository;
  final Json series;
  @override
  State<_KomfContent> createState() => _KomfContentState();
}

class _KomfContentState extends State<_KomfContent> {
  late final _search = TextEditingController(
    text: text(
      object(widget.series['metadata'])['title'],
      text(widget.series['name']),
    ),
  );
  Timer? _debounce;
  List<Json> _results = [];
  Object? _error;
  int _generation = 0;
  bool _searching = false, _submitting = false;
  String get _seriesId => text(widget.series['id']);
  String get _libraryId => text(widget.series['libraryId']);
  String get _title => text(
    object(widget.series['metadata'])['title'],
    text(widget.series['name']),
  );
  Komf get _komf => widget.repository.komf;
  @override
  void initState() {
    super.initState();
    _search.addListener(_queryChanged);
    _queryChanged();
  }

  void _queryChanged() {
    final generation = ++_generation;
    _debounce?.cancel();
    setState(() {
      _error = null;
      _searching = _search.text.trim().isNotEmpty;
      _results = [];
    });
    if (_search.text.trim().isEmpty) return;
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _runSearch(generation),
    );
  }

  Future<void> _runSearch(int generation) async {
    try {
      final results = await _komf.search(
        name: _search.text,
        libraryId: _libraryId,
        seriesId: _seriesId,
      );
      if (mounted && generation == _generation) {
        setState(() {
          _results = results;
          _searching = false;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error;
          _searching = false;
        });
      }
    }
  }

  Future<void> _submit({
    KomfProviderLink? link,
    Json? result,
    bool reset = false,
  }) async {
    if (_submitting) return;
    if (reset &&
        !await confirm(
          context,
          'Reset Metadata',
          'Reset this series metadata using Komf?',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _submitting = true);
    try {
      if (reset) {
        await _komf.reset(libraryId: _libraryId, seriesId: _seriesId);
      } else if (link != null || result != null) {
        await _komf.identify(
          libraryId: _libraryId,
          seriesId: _seriesId,
          title: _title,
          provider: link?.provider ?? text(result!['provider']),
          providerSeriesId: link?.id ?? text(result!['resultId']),
        );
      } else {
        await _komf.match(
          libraryId: _libraryId,
          seriesId: _seriesId,
          title: _title,
        );
      }
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Widget _provider(
    String provider,
    String id,
    String title, {
    String? caption,
    Uri? url,
    Uri? image,
    VoidCallback? onTap,
  }) => ListTile(
    leading:
        image != null && isExternalWebLink(image) && !widget.repository.offline
        ? ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.network(
              image.toString(),
              width: 40,
              height: 60,
              fit: BoxFit.cover,
              cacheWidth: 120,
              errorBuilder: (_, _, _) => const SizedBox(
                width: 40,
                height: 60,
                child: Icon(Icons.broken_image_outlined),
              ),
            ),
          )
        : const Icon(Icons.link),
    title: Text(title),
    subtitle: Text(caption ?? '$provider · $id'),
    onTap: _submitting || widget.repository.offline ? null : onTap,
    trailing: url != null && isExternalWebLink(url)
        ? IconButton(
            tooltip: tr(context, 'Open in Browser'),
            onPressed: () async {
              try {
                await openExternalWebLink(url);
              } catch (error) {
                if (mounted) showError(context, error);
              }
            },
            icon: const Icon(Icons.open_in_new),
          )
        : null,
  );

  @override
  Widget build(BuildContext context) {
    final links = komfProviderLinks(
      widget.series['providerLinks'] as List? ?? [],
    );
    return ListenableBuilder(
      listenable: Listenable.merge([widget.repository, _komf]),
      builder: (context, _) {
        final jobs = _komf.jobs.values
            .where((job) => job['seriesId'] == _seriesId)
            .toList()
            .reversed;
        final busy =
            _submitting ||
            !_komf.connected ||
            widget.repository.offline ||
            jobs.any((job) => job['status'] == 'RUNNING');
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (_submitting) const LinearProgressIndicator(),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: busy ? null : () => _submit(),
                  icon: const Icon(Icons.sync),
                  label: Text(tr(context, 'Match')),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _submit(reset: true),
                  icon: const Icon(Icons.restore),
                  label: Text(tr(context, 'Reset Metadata')),
                ),
              ],
            ),
            for (final job in jobs)
              Card(
                child: ListTile(
                  leading: job['status'] == 'RUNNING'
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          job['status'] == 'COMPLETED'
                              ? Icons.check_circle_outline
                              : Icons.info_outline,
                        ),
                  title: Text(
                    tr(context, switch (job['status']) {
                      'RUNNING' => 'Komf job running',
                      'COMPLETED' => 'Komf job completed',
                      'FAILED' => 'Komf job failed',
                      _ => 'Komf tracking stopped; the server job may still be running.',
                    }),
                  ),
                  subtitle: job['message'] == null
                      ? null
                      : Text(text(job['message'])),
                ),
              ),
            const SizedBox(height: 20),
            TextField(
              controller: _search,
              enabled: !_submitting && !widget.repository.offline,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) {
                _debounce?.cancel();
                _queryChanged();
              },
              decoration: InputDecoration(
                labelText: tr(context, 'Search komf providers…'),
                prefixIcon: const Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 16),
            if (links.isNotEmpty) ...[
              Text(
                tr(context, 'Provider Links'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (links.length > 1)
                _provider(
                  links.first.provider,
                  links.first.id,
                  tr(context, 'Aggregate all providers'),
                  onTap: busy ? null : () => _submit(link: links.first),
                ),
              for (final link in links)
                _provider(
                  link.provider,
                  link.id,
                  link.provider,
                  url: link.url,
                  onTap: busy ? null : () => _submit(link: link),
                ),
              const Divider(),
            ],
            if (_searching) const Center(child: CircularProgressIndicator()),
            if (_error != null)
              FailureView(error: _error!, retry: _queryChanged),
            if (!_searching &&
                _error == null &&
                _results.isEmpty &&
                _search.text.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(tr(context, 'No Results')),
              ),
            for (final result in _results)
              _provider(
                text(result['provider']),
                text(result['resultId']),
                text(result['title']),
                caption: [
                  result['provider'],
                  result['mediaType'],
                  result['language'],
                ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                url: Uri.tryParse(text(result['url'])),
                image: Uri.tryParse(text(result['imageUrl'])),
                onTap: busy ? null : () => _submit(result: result),
              ),
          ],
        );
      },
    );
  }
}
