import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/file_export.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'reader_display.dart';

/// An isolated full page leaves the parent reader's position and layout intact.
class PageImageView extends StatefulWidget {
  const PageImageView({
    super.key,
    required this.bytes,
    required this.directory,
    required this.title,
    required this.page,
    this.keepAwake = false,
    this.fullscreen = false,
  });
  final Uint8List bytes;
  final Directory directory;
  final String title;
  final int page;
  final bool keepAwake, fullscreen;
  @override
  State<PageImageView> createState() => _PageImageViewState();
}

class _PageImageViewState extends State<PageImageView> {
  bool _saving = false;
  final _zoom = TransformationController();
  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await saveEncodedPageImage(
        widget.bytes,
        widget.directory,
        page: widget.page,
      );
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ReaderDisplay(
    keepAwake: widget.keepAwake,
    fullscreen: widget.fullscreen,
    child: ReaderSafeArea(
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(
            '${widget.title} · ${widget.page}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: tr(context, 'Save Image'),
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_alt),
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, box) => InteractiveViewer(
            transformationController: _zoom,
            maxScale: 8,
            child: SizedBox(
              width: box.maxWidth,
              height: box.maxHeight,
              child: Image.memory(widget.bytes, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    ),
  );
}
