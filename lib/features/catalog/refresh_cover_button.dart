import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';

class RefreshCoverButton extends StatefulWidget {
  const RefreshCoverButton({
    super.key,
    required this.repository,
    required this.item,
  });
  final Repository repository;
  final CatalogItem item;
  @override
  State<RefreshCoverButton> createState() => _State();
}

class _State extends State<RefreshCoverButton> {
  bool busy = false;
  Future<void> refresh() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.repository.refreshCover(widget.item);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'Cover refreshed.'))),
        );
      }
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.repository,
    builder: (context, _) => IconButton(
      tooltip: tr(context, 'Refresh cover'),
      onPressed: busy || widget.repository.offline ? null : refresh,
      icon: const Icon(Icons.refresh),
    ),
  );
}
