import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/repository.dart';
import 'strings.dart';

Future<T?> chooseValue<T>(
  BuildContext context, {
  required String title,
  required T selected,
  required Map<T, String> choices,
  bool translateChoices = true,
  bool searchable = false,
}) {
  var query = '';
  Widget content(BuildContext sheet) => StatefulBuilder(
    builder: (sheet, update) {
      String label(String value) => translateChoices ? tr(sheet, value) : value;
      final entries = choices.entries
          .where(
            (entry) =>
                label(entry.value).toLowerCase().contains(query.toLowerCase()),
          )
          .toList();
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                tr(sheet, title),
                style: Theme.of(sheet).textTheme.titleLarge,
              ),
            ),
            if (searchable)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: tr(sheet, 'Search'),
                    prefixIcon: const Icon(CupertinoIcons.search),
                  ),
                  onChanged: (value) => update(() => query = value),
                ),
              ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return ListTile(
                    title: Text(label(entry.value)),
                    selected: entry.key == selected,
                    trailing: entry.key == selected
                        ? const Icon(CupertinoIcons.check_mark, size: 20)
                        : null,
                    onTap: () => Navigator.pop(sheet, entry.key),
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
  if (MediaQuery.sizeOf(context).width >= 700) {
    return showDialog<T>(
      context: context,
      builder: (sheet) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 420,
            maxHeight: MediaQuery.sizeOf(sheet).height * .8,
          ),
          child: content(sheet),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheet).height * .8,
      ),
      child: content(sheet),
    ),
  );
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(error.toString())));
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, title)),
        content: Text(tr(context, message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'Continue')),
          ),
        ],
      ),
    ) ??
    false;

class FailureView extends StatelessWidget {
  const FailureView({super.key, required this.error, required this.retry});
  final Object error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(CupertinoIcons.exclamationmark_circle, size: 44),
          const SizedBox(height: 16),
          Text(tr(context, error.toString()), textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton(onPressed: retry, child: Text(tr(context, 'Retry'))),
        ],
      ),
    ),
  );
}

class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.title,
    this.message,
    this.icon = CupertinoIcons.book,
  });
  final String title;
  final String? message;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: Theme.of(context).hintColor),
          const SizedBox(height: 16),
          Text(
            tr(context, title),
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          if (message != null) ...[
            const SizedBox(height: 10),
            Text(tr(context, message!), textAlign: TextAlign.center),
          ],
        ],
      ),
    ),
  );
}

class Cover extends StatefulWidget {
  const Cover({
    super.key,
    required this.repository,
    required this.path,
    this.fit = BoxFit.cover,
  });
  final Repository repository;
  final String path;
  final BoxFit fit;
  @override
  State<Cover> createState() => _CoverState();
}

class _CoverState extends State<Cover> {
  late Future<Uint8List> _image;
  @override
  void initState() {
    super.initState();
    _image = widget.repository.image(widget.path);
  }

  @override
  void didUpdateWidget(Cover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.repository != widget.repository) {
      _image = widget.repository.image(widget.path);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _image,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final physicalWidth =
                constraints.maxWidth * MediaQuery.devicePixelRatioOf(context);
            final width = [
              128,
              256,
              512,
              1024,
            ].firstWhere((v) => v >= physicalWidth, orElse: () => 1024);
            return Image.memory(
              snapshot.data!,
              cacheWidth: width,
              fit: widget.fit,
              gaplessPlayback: true,
              errorBuilder: (context, error, stack) =>
                  const Icon(CupertinoIcons.book),
            );
          },
        );
      }
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: snapshot.hasError
              ? const Icon(CupertinoIcons.book)
              : const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
        ),
      );
    },
  );
}

class AsyncPanel<T> extends StatefulWidget {
  const AsyncPanel({
    super.key,
    required this.load,
    required this.builder,
    this.revision = 0,
  });
  final int revision;
  final Future<T> Function() load;
  final Widget Function(BuildContext, T) builder;
  @override
  State<AsyncPanel<T>> createState() => _AsyncPanelState<T>();
}

class _AsyncPanelState<T> extends State<AsyncPanel<T>> {
  late Future<T> _future;
  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  void _reload() => setState(() => _future = widget.load());
  @override
  void didUpdateWidget(AsyncPanel<T> old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision) _future = widget.load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.hasError && !snapshot.hasData) {
        return FailureView(error: snapshot.error!, retry: _reload);
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator.adaptive());
      }
      return RefreshIndicator(
        onRefresh: () async {
          _reload();
          try {
            await _future;
          } catch (_) {}
        },
        child: widget.builder(context, snapshot.data as T),
      );
    },
  );
}
