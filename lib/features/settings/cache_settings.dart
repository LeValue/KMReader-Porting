import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/media_cache.dart';
import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/section_scroll_view.dart';
import '../../ui/strings.dart';
import 'preference_controls.dart';
import 'settings_style.dart';

class CacheSettingsPage extends StatefulWidget {
  const CacheSettingsPage({super.key, required this.repository});
  final Repository repository;
  @override
  State<CacheSettingsPage> createState() => _CacheSettingsPageState();
}

typedef _StorageUsage = ({
  List<MediaCacheStats> images,
  int documentBytes,
  int removableDocumentBytes,
  int offlineBytes,
});

class _CacheSettingsPageState extends State<CacheSettingsPage> {
  late Future<_StorageUsage> _stats;
  Timer? _trim;
  bool _busy = false;
  Future<_StorageUsage> _load() async {
    final repository = widget.repository;
    final offlineBytes = repository.store
        .downloads(repository.profile.id)
        .where((item) => item['status'] == 'ready')
        .fold(0, (bytes, item) => bytes + integer(item['size']));
    final images = await Future.wait([
      for (final kind in MediaCacheKind.values)
        repository.mediaCache.stats(kind),
    ]);
    final documents = await repository.documents.usage();
    return (
      images: images,
      documentBytes: documents.bytes,
      removableDocumentBytes: documents.removableBytes,
      offlineBytes: offlineBytes,
    );
  }

  String _size(BuildContext context, int? bytes) {
    if (bytes == null) return '…';
    const mib = 1024 * 1024;
    final gb = bytes >= 1024 * mib;
    final format = NumberFormat.decimalPatternDigits(
      locale: Localizations.localeOf(context).toString(),
      decimalDigits: 1,
    );
    return '${format.format(bytes / (gb ? 1024 * mib : mib))} ${gb ? 'GB' : 'MB'}';
  }

  @override
  void initState() {
    super.initState();
    _stats = _load();
  }

  @override
  void dispose() {
    _trim?.cancel();
    super.dispose();
  }

  void _scheduleTrim(String _) {
    _trim?.cancel();
    _trim = Timer(const Duration(milliseconds: 800), () async {
      try {
        await widget.repository.mediaCache.trim();
        if (mounted) setState(() => _stats = _load());
      } catch (error) {
        if (mounted) showError(context, error);
      }
    });
  }

  Future<void> _clear(MediaCacheKind kind, bool all) async {
    if (!await confirm(
          context,
          all ? 'Clear All' : 'Clear Current',
          'Downloaded books and reading progress are kept.',
        ) ||
        !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.repository.clearImageCache(kind: kind, allAccounts: all);
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _stats = _load();
        });
      }
    }
  }

  Future<void> _clearDocuments() async {
    if (!await confirm(
          context,
          'Clear Temporary Documents',
          'Downloaded books and open documents are kept.',
        ) ||
        !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.repository.documents.trim(clear: true);
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _stats = _load();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: 'Cache',
    actions: [
      IconButton(
        tooltip: tr(context, 'Refresh'),
        onPressed: () => setState(() => _stats = _load()),
        icon: const Icon(Icons.refresh),
      ),
    ],
    body: FutureBuilder(
      future: _stats,
      builder: (context, snapshot) => SectionScrollView(
        padding: const EdgeInsets.all(22),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: Text(tr(context, 'settings.cache.scope')),
          ),
          if (snapshot.hasError) Text('${snapshot.error}'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.download_done),
              title: Text(tr(context, 'Completed Downloads')),
              trailing: Text(_size(context, snapshot.data?.offlineBytes)),
            ),
          ),
          for (final kind in MediaCacheKind.values) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 0, 10),
              child: Text(
                tr(context, kind == MediaCacheKind.pages ? 'Page' : 'Cover'),
              ),
            ),
            Card(
              child: Column(
                children: [
                  PreferencePage(
                    title: 'Cache',
                    embedded: true,
                    decorateGroups: false,
                    store: widget.repository.store,
                    onChanged: _scheduleTrim,
                    specs: kind == MediaCacheKind.pages
                        ? [
                            PreferenceSpec(
                              'maxPageCacheSize',
                              'Maximum Size',
                              8,
                              min: 1,
                              max: 20,
                              formatValue: (v) => '${v.round()} GB',
                              caption: 'Adjust the maximum size of the page cache. Cache will be cleaned automatically when exceeded.',
                            ),
                          ]
                        : [
                            PreferenceSpec(
                              'maxCoverCacheSize',
                              'Maximum Size',
                              512,
                              min: 128,
                              max: 8192,
                              step: 128,
                              formatValue: (v) => '${v.round()} MB',
                              caption: 'Adjust the maximum size of the cover cache. Cache will be cleaned automatically when exceeded.',
                            ),
                            PreferenceSpec(
                              'coverCacheExpirationDays',
                              'Expiration',
                              7,
                              min: 1,
                              max: 90,
                              formatValue: (v) =>
                                  '${v.round()} ${tr(context, 'Days')}',
                              caption:
                                  'Refresh cached covers after this many days.',
                            ),
                          ],
                  ),
                  const Divider(indent: 20, endIndent: 20),
                  ListTile(
                    title: Text(tr(context, 'Cached Size')),
                    trailing: Text(
                      _size(context, snapshot.data?.images[kind.index].bytes),
                    ),
                  ),
                  const Divider(indent: 20, endIndent: 20),
                  ListTile(
                    title: Text(
                      tr(
                        context,
                        kind == MediaCacheKind.pages
                            ? 'Cached Images'
                            : 'Cached Covers',
                      ),
                    ),
                    trailing: Text(
                      snapshot.hasData
                          ? '${snapshot.data!.images[kind.index].entries}'
                          : '…',
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        textButtonTheme: TextButtonThemeData(
                          style: TextButton.styleFrom(
                            backgroundColor: Theme.of(context).dividerColor
                                .withValues(alpha: .08),
                            foregroundColor: Colors.red,
                          ),
                        ),
                      ),
                      child: Row(
                        spacing: 8,
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _clear(kind, true),
                              child: Text(
                                tr(context, 'Clear All'),
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          ),
                          Expanded(
                            child: TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _clear(kind, false),
                              child: Text(
                                tr(context, 'Clear Current'),
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
          ],
          PreferencePage(
            title: 'Document Cache Limit',
            embedded: true,
            store: widget.repository.store,
            onChanged: (_) => widget.repository.documents.scheduleTrim(),
            specs: [
              PreferenceSpec(
                'documentCacheMb',
                'Document Cache Limit',
                1024,
                section: 'Documents',
                choices: {
                  128: '128 MB',
                  256: '256 MB',
                  512: '512 MB',
                  1024: '1 GB',
                  2048: '2 GB',
                  4096: '4 GB',
                  8192: '8 GB',
                },
              ),
            ],
          ),
          ListTile(
            title: Text(tr(context, 'Cached Documents')),
            trailing: Text(_size(context, snapshot.data?.documentBytes)),
          ),
          ListTile(
            title: Text(tr(context, 'Clear Temporary Documents')),
            subtitle: Text(
              tr(context, 'Downloaded books and open documents are kept.'),
            ),
            trailing: Text(
              _size(context, snapshot.data?.removableDocumentBytes),
            ),
            onTap: _busy || snapshot.data?.removableDocumentBytes == 0
                ? null
                : _clearDocuments,
          ),
        ],
      ),
    ),
  );
}
