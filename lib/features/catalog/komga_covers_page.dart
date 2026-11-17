import 'package:flutter/material.dart';

import '../../core/komga_library_admin.dart';
import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';

class KomgaCoversPage extends StatefulWidget {
  const KomgaCoversPage({
    super.key,
    required this.repository,
    required this.item,
  });
  final Repository repository;
  final CatalogItem item;
  @override
  State<KomgaCoversPage> createState() => _State();
}

class _State extends State<KomgaCoversPage> {
  late final admin = KomgaLibraryAdmin(widget.repository);
  List<Json> rows = [];
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final next = await admin.covers(widget.item.kind, widget.item.id);
      if (mounted) {
        setState(() {
          rows = next;
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> change(Json row, {bool remove = false}) async {
    if (busy) return;
    if (remove &&
        !await confirm(
          context,
          'Remove uploaded cover',
          '${widget.item.title}\n\n${tr(context, 'Remove this uploaded image from Komga? Other available covers and the book file are kept.')}',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (remove) {
        await admin.removeCover(
          widget.item.kind,
          widget.item.id,
          text(row['id']),
        );
      } else {
        await admin.selectCover(
          widget.item.kind,
          widget.item.id,
          text(row['id']),
        );
      }
    } catch (failure) {
      if (mounted) {
        setState(() => busy = false);
        showError(context, failure);
      }
      return;
    }
    // Read-back errors must not invite an automatic replay of a successful write.
    if (mounted) await load();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.repository,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Available covers')),
        actions: [
          IconButton(
            tooltip: tr(context, 'Refresh'),
            onPressed: busy
                ? null
                : () {
                    setState(() => busy = true);
                    load();
                  },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            widget.item.title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text(
            tr(
              context,
              'Choose an existing cover to restore it. Only uploaded images can be removed. Your book files are kept.',
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(tr(context, error!)),
            ),
          if (!busy && error == null && rows.isEmpty)
            Text(
              tr(context, 'No custom covers. Komga uses its default cover.'),
            ),
          for (final (index, row) in rows.indexed)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              leading: SizedBox(
                width: 56,
                height: 80,
                child: Cover(
                  repository: widget.repository,
                  path:
                      '/api/v1/${widget.item.kind}/${Uri.encodeComponent(widget.item.id)}/thumbnails/${Uri.encodeComponent(text(row['id']))}',
                ),
              ),
              title: Text(
                '${tr(context, switch (row['type']) {
                  'GENERATED' => 'From document',
                  'USER_UPLOADED' => 'Uploaded cover',
                  _ => 'From library',
                })} ${index + 1}',
              ),
              subtitle: row['selected'] == true
                  ? Text(tr(context, 'Current cover'))
                  : null,
              onTap:
                  busy || widget.repository.offline || row['selected'] == true
                  ? null
                  : () => change(row),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (row['selected'] == true) const Icon(Icons.check_circle),
                  if (row['type'] == 'USER_UPLOADED')
                    IconButton(
                      tooltip: tr(context, 'Remove uploaded cover'),
                      onPressed: busy || widget.repository.offline
                          ? null
                          : () => change(row, remove: true),
                      icon: const Icon(Icons.delete_outline),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
