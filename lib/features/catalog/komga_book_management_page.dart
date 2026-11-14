import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/komga_library_admin.dart';
import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'metadata_editor.dart';

class KomgaBookManagementPage extends StatefulWidget {
  const KomgaBookManagementPage({
    super.key,
    required this.repository,
    required this.item,
  });
  final Repository repository;
  final CatalogItem item;
  @override
  State<KomgaBookManagementPage> createState() => _State();
}

class _State extends State<KomgaBookManagementPage> {
  late final admin = KomgaLibraryAdmin(widget.repository);
  final cancel = Completer<void>();
  bool busy = false;
  String? message;
  @override
  void dispose() {
    if (!cancel.isCompleted) cancel.complete();
    super.dispose();
  }

  Future<void> cover() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Cover',
          extensions: ['jpg', 'jpeg', 'png', 'webp'],
          mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await admin.cover(widget.item.kind, widget.item.id, file, cancel.future);
      if (mounted) {
        setState(() => message = tr(context, 'Cover updated on Komga.'));
      }
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove() async {
    if (!await confirm(
      context,
      'Delete from Komga',
      '${widget.item.title}\n\n${tr(context, 'This deletes the original file on the Komga server for every user. This cannot be undone.')}',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await admin.deleteBook(widget.item.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              context,
              'Deletion requested. Komga will update the library after processing.',
            ),
          ),
        ),
      );
      Navigator.pop(context, 'delete-requested');
    } catch (error) {
      if (mounted) {
        setState(() => busy = false);
        showError(context, error);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'Manage on Komga'))),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(widget.item.title, style: Theme.of(context).textTheme.titleLarge),
        ListTile(
          leading: const Icon(Icons.edit),
          title: Text(tr(context, 'Edit information')),
          enabled: !busy && !widget.repository.offline,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => MetadataEditor(
                repository: widget.repository,
                item: widget.item,
              ),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.image),
          title: Text(tr(context, 'Change cover')),
          enabled: !busy && !widget.repository.offline,
          onTap: cover,
        ),
        if (widget.item.kind == 'books')
          ListTile(
            leading: const Icon(Icons.delete_forever),
            title: Text(tr(context, 'Delete from Komga')),
            enabled: !busy && !widget.repository.offline,
            onTap: remove,
          ),
        if (busy) const LinearProgressIndicator(),
        if (message != null)
          Padding(padding: const EdgeInsets.all(16), child: Text(message!)),
      ],
    ),
  );
}
