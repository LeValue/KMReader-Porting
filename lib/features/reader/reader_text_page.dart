import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'reader_ocr.dart';

class ReaderTextPage extends StatefulWidget {
  const ReaderTextPage({
    super.key,
    required this.bytes,
    required this.ocr,
    required this.title,
    this.incognito = false,
  });
  final Uint8List bytes;
  final ReaderOcr ocr;
  final String title;
  final bool incognito;
  @override
  State<ReaderTextPage> createState() => _ReaderTextPageState();
}

class _ReaderTextPageState extends State<ReaderTextPage> {
  List<String> _languages = [];
  String? _language, _error;
  OcrDocument? _document;
  bool _busy = true, _overlay = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final languages = await widget.ocr.languages();
      if (!mounted) return;
      if (languages.isEmpty) {
        throw StateError(
          'Install an OCR language pack in your device settings.',
        );
      }
      setState(() {
        _languages = languages;
        _language = languages.contains('latin') ? 'latin' : languages.first;
      });
      await _recognize();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _busy = false;
        });
      }
    }
  }

  Future<void> _recognize() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final document = await widget.ocr.recognize(
        widget.bytes,
        _language!,
        cache: !widget.incognito,
      );
      if (mounted && generation == _generation) {
        setState(() => _document = document);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'Recognize Text')),
      actions: [
        IconButton(
          tooltip: tr(context, 'Copy All'),
          onPressed: _document == null
              ? null
              : () => Clipboard.setData(ClipboardData(text: _document!.text)),
          icon: const Icon(Icons.copy_all),
        ),
        IconButton(
          tooltip: tr(context, 'Show Text Regions'),
          onPressed: _document == null
              ? null
              : () => setState(() => _overlay = !_overlay),
          icon: Icon(_overlay ? Icons.subject : Icons.image_search),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 16),
                if (_languages.isNotEmpty)
                  DropdownButton<String>(
                    value: _language,
                    items: [
                      for (final language in _languages)
                        DropdownMenuItem(
                          value: language,
                          child: Text(
                            {
                                  'latin': 'Latin',
                                  'ja': '日本語',
                                  'zh': '中文',
                                  'ko': '한국어',
                                  'hi': 'हिन्दी',
                                }[language] ??
                                language,
                          ),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) {
                            setState(() => _language = value);
                            unawaited(_recognize());
                          },
                  ),
              ],
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: _error != null
                ? FailureView(
                    error: _error!,
                    retry: _languages.isEmpty ? _open : _recognize,
                  )
                : _document == null
                ? const Center(child: CircularProgressIndicator.adaptive())
                : _overlay
                ? _regions()
                : _text(),
          ),
        ],
      ),
    ),
  );
  Widget _text() {
    final doc = _document!;
    if (doc.text.trim().isEmpty) {
      return const EmptyView(
        title: 'No Text Found',
        message: 'Choose another recognition language or page.',
        icon: Icons.text_fields,
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: SelectionArea(
        child: Text(doc.text, style: Theme.of(context).textTheme.bodyLarge),
      ),
    );
  }

  Widget _regions() => InteractiveViewer(
    minScale: 1,
    maxScale: 6,
    child: Center(
      child: AspectRatio(
        aspectRatio: _document!.width / _document!.height,
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(widget.bytes, fit: BoxFit.fill),
              for (final block in _document!.blocks)
                Positioned(
                  left: block.bounds.left * box.maxWidth,
                  top: block.bounds.top * box.maxHeight,
                  width: block.bounds.width * box.maxWidth,
                  height: block.bounds.height * box.maxHeight,
                  child: InkWell(
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        content: SelectableText(block.text),
                        actions: [
                          TextButton(
                            onPressed: () => Clipboard.setData(
                              ClipboardData(text: block.text),
                            ),
                            child: Text(tr(context, 'Copy')),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: Text(tr(context, 'Close')),
                          ),
                        ],
                      ),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: .16),
                        border: Border.all(color: Colors.blue, width: 1.5),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
