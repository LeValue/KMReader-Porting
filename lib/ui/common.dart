import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/repository.dart';
import 'strings.dart';
import 'choice_menu.dart';

Future<T?> chooseValue<T>(
  BuildContext context, {
  required String title,
  required T selected,
  required Map<T, String> choices,
  bool translateChoices = true,
  bool searchable = false,
  bool anchored = false,
}) async {
  ModalRoute<dynamic>? pickerRoute;
  if (anchored && !searchable && choices.length <= 20) {
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final row = context.findRenderObject()! as RenderBox;
    final origin = row.localToGlobal(Offset.zero, ancestor: overlay);
    if (choices.length > 8) {
      return showChoiceMenu<T>(
        context,
        anchor: origin & row.size,
        selected: selected,
        labels: {
          for (final entry in choices.entries)
            entry.key: translateChoices
                ? tr(context, entry.value)
                : entry.value,
        },
      );
    }
    final value = await showMenu<T>(
      context: context,
      position: RelativeRect.fromLTRB(
        origin.dx + row.size.width * .45,
        origin.dy + row.size.height,
        16,
        0,
      ),
      constraints: BoxConstraints(
        minWidth: 220,
        maxWidth: (MediaQuery.sizeOf(context).width - 32).clamp(220, 420),
      ),
      initialValue: selected,
      items: [
        for (final entry in choices.entries)
          CheckedPopupMenuItem<T>(
            value: entry.key,
            checked: entry.key == selected,
            child: Builder(
              builder: (menu) {
                pickerRoute = ModalRoute.of(menu);
                return Text(
                  translateChoices ? tr(context, entry.value) : entry.value,
                );
              },
            ),
          ),
      ],
    );
    await pickerRoute?.completed;
    return value;
  }
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
    final value = await showDialog<T>(
      context: context,
      builder: (sheet) {
        pickerRoute = ModalRoute.of(sheet);
        return Dialog(
          child: RepaintBoundary(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 420,
                maxHeight: MediaQuery.sizeOf(sheet).height * .8,
              ),
              child: content(sheet),
            ),
          ),
        );
      },
    );
    await pickerRoute?.completed;
    return value;
  }
  final value = await showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    sheetAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 200),
      reverseDuration: Duration(milliseconds: 160),
    ),
    builder: (sheet) {
      pickerRoute = ModalRoute.of(sheet);
      return RepaintBoundary(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheet).height * .8,
          ),
          child: content(sheet),
        ),
      );
    },
  );
  await pickerRoute?.completed;
  return value;
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(tr(context, error.toString()))));
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
    this.frameBuilder,
  });
  final Repository repository;
  final String path;
  final BoxFit fit;
  final ImageFrameBuilder? frameBuilder;
  @override
  State<Cover> createState() => _CoverState();
}

class _CoverState extends State<Cover> {
  late Future<Uint8List> _image;
  void _changed() {
    if (mounted && widget.repository.imageChanges.value.contains(widget.path)) {
      setState(() => _image = widget.repository.image(widget.path));
    }
  }

  @override
  void initState() {
    super.initState();
    _image = widget.repository.image(widget.path);
    widget.repository.imageChanges.addListener(_changed);
  }

  @override
  void dispose() {
    widget.repository.imageChanges.removeListener(_changed);
    super.dispose();
  }

  @override
  void didUpdateWidget(Cover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.imageChanges.removeListener(_changed);
      widget.repository.imageChanges.addListener(_changed);
    }
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
              excludeFromSemantics: widget.frameBuilder != null,
              frameBuilder: widget.frameBuilder == null
                  ? null
                  : (context, child, frame, synchronous) {
                      // Use the decoded native frame without a second codec or stream.
                      final image = switch (child) {
                        RawImage(image: final source?) => AspectRatio(
                          aspectRatio: source.width / source.height,
                          child: child,
                        ),
                        _ => child,
                      };
                      return Semantics(
                        image: true,
                        child: widget.frameBuilder!(
                          context,
                          image,
                          frame,
                          synchronous,
                        ),
                      );
                    },
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
    this.pullToRefresh = true,
    this.loading,
  });
  final bool pullToRefresh;
  final Widget? loading;
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
        return widget.loading ??
            const Center(child: CircularProgressIndicator.adaptive());
      }
      if (!widget.pullToRefresh) {
        return widget.builder(context, snapshot.data as T);
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
