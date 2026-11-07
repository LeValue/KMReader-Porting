import 'package:flutter/material.dart';

import '../../core/kindle/management.dart';
import '../../core/kindle/chrome.dart';
import '../../core/kindle/repository.dart';
import '../../core/models.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'kindle_import_page.dart';

class KindleDocumentPage extends StatefulWidget {
  const KindleDocumentPage({
    super.key,
    required this.repository,
    required this.book,
  });
  final KindleRepository repository;
  final Book book;
  @override
  State<KindleDocumentPage> createState() => _KindleDocumentPageState();
}

class _KindleDocumentPageState extends State<KindleDocumentPage> {
  late final _manager = KindleDocumentManager(widget.repository);
  bool _busy = false;
  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'Manage Kindle document'))),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(widget.book.title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),
        ListTile(
          leading: const Icon(Icons.edit),
          title: Text(tr(context, 'Edit metadata and cover')),
          subtitle: Text(
            tr(
              context,
              'Prepare and send an updated EPUB copy; the original remains available.',
            ),
          ),
          enabled: !_busy && !widget.repository.offline,
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => KindleImportPage(
                  repository: widget.repository,
                  replacing: widget.book,
                ),
              ),
            );
            if (mounted) setState(() {});
          },
        ),
        ListTile(
          leading: Icon(
            Icons.delete_forever,
            color: Theme.of(context).colorScheme.error,
          ),
          title: Text(tr(context, 'Delete from Kindle library')),
          subtitle: Text(
            tr(
              context,
              'Permanently removes this personal document from Amazon, not just this device. Local files and recovery data are kept.',
            ),
          ),
          enabled: !_busy && !widget.repository.offline,
          onTap: () async {
            if (!await confirm(
              context,
              'Delete from Kindle library',
              'Permanently removes this personal document from Amazon, not just this device. Local files and recovery data are kept.',
            )) {
              return;
            }
            await _run(() => _manager.delete(widget.book));
          },
        ),
        TextButton.icon(
          onPressed: () => openKindleChrome(
            Uri.parse(
              'https://www.amazon.it/hz/mycd/myx#/home/content/pdocs/dateDsc/',
            ),
          ),
          icon: const Icon(Icons.open_in_browser),
          label: Text(tr(context, 'Open Amazon content manager')),
        ),
        if (_busy) const LinearProgressIndicator(),
        for (final operation in _manager.operations.where(
          (op) => op['book'] == widget.book.id && op['state'] == 'backed_up',
        ))
          TextButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    _manager.abandonBeforeSubmission(
                      text(operation['operation']),
                    );
                  }),
            child: Text(tr(context, 'Cancel operation before sending')),
          ),
        for (final operation in _manager.operations.where(
          (op) => op['book'] == widget.book.id,
        ))
          ListTile(
            title: Text(
              tr(context, switch (operation['state']) {
                'done' => 'Deletion confirmed by Amazon catalog',
                'rejected' => 'Operation stopped before sending',
                'replacement_migration_required' =>
                  'Updated copy sent; state migration incomplete',
                'replacement_uncertain' => 'Delivery uncertain. Check your Kindle library before sending again.',
                'replacement_submitting' => 'Delivery interrupted. Check your Kindle library before sending again.',
                _ => 'Deletion awaiting verification',
              }),
            ),
            subtitle: Text(text(operation['updated'])),
            trailing:
                operation['kind'] == 'delete' &&
                    operation['state'] != 'done' &&
                    operation['state'] != 'rejected'
                ? IconButton(
                    tooltip: tr(context, 'Check deletion'),
                    icon: const Icon(Icons.refresh),
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await _manager.verifyDeletion(
                              text(operation['operation']),
                            );
                          }),
                  )
                : null,
          ),
      ],
    ),
  );
}
