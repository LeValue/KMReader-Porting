import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/translation.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../settings/translation_settings.dart';
import 'reader_display.dart';
import 'reader_ocr.dart';
import 'bubble_detector.dart';

class ReaderTextPage extends StatefulWidget {
  const ReaderTextPage({
    super.key,
    this.bytes,
    this.ocr,
    this.detector,
    this.initialText,
    required this.providers,
    required this.title,
    this.incognito = false,
  }) : assert(initialText != null || bytes != null && ocr != null);
  final Uint8List? bytes;
  final ReaderOcr? ocr;
  final BubbleDetector? detector;
  final String? initialText;
  final TranslationProviders providers;
  final String title;
  final bool incognito;
  @override
  State<ReaderTextPage> createState() => _ReaderTextPageState();
}

class _ReaderTextPageState extends State<ReaderTextPage> {
  List<String> _languages = [];
  String? _language, _error;
  OcrDocument? _document;
  List<String>? _translations;
  bool _busy = true,
      _overlay = false,
      _translating = false,
      _translated = false;
  int _generation = 0;
  final _client = TranslationClient();
  late bool _groupBubbles =
      widget.providers.store.setting<bool>('ocrGroupBubbles') == true;
  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    if (widget.initialText != null) {
      _document = OcrDocument(1, 1, widget.initialText!, [
        OcrBlock(widget.initialText!, const Rect.fromLTWH(0, 0, 1, 1)),
      ]);
      _language = 'auto';
      _busy = false;
      return;
    }
    try {
      final languages = await widget.ocr!.languages();
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
      _translations = null;
      _translated = false;
    });
    try {
      var doc = await widget.ocr!.recognize(
        widget.bytes!,
        _language!,
        cache: !widget.incognito,
      );
      if (!mounted || generation != _generation) return;
      if (_groupBubbles && widget.detector != null) {
        try {
          final detection = await widget.detector!.detect(
            widget.bytes!,
            cache: !widget.incognito,
          );
          doc = groupOcrBubbles(doc, detection.boxes);
        } catch (_) {
          if (mounted && generation == _generation) {
            showError(
              context,
              tr(
                context,
                'Bubble detection failed. System OCR regions are still available.',
              ),
            );
          }
        }
      }
      if (mounted && generation == _generation) setState(() => _document = doc);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _settings() async {
    if (_translating) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderDisplay(
          child: TranslationSettingsPage(
            providers: widget.providers,
            immersive: true,
          ),
        ),
      ),
    );
    if (mounted) {
      setState(() {
        _translations = null;
        _translated = false;
      });
    }
  }

  Future<void> _translate() async {
    if (_translations != null) {
      setState(() => _translated = !_translated);
      return;
    }
    if (widget.providers.active == null) await _settings();
    if (!mounted || widget.providers.active == null) return;
    final generation = _generation,
        doc = _document!,
        provider = widget.providers.active!;
    setState(() => _translating = true);
    try {
      final key = await widget.providers.key(provider.id);
      final segments = doc.blocks.isEmpty
          ? [doc.text]
          : doc.blocks.map((b) => b.text).toList();
      final target =
          widget.providers.store.setting<String>('translationTarget') ?? 'it';
      final source = _language == 'latin' ? 'auto' : _language ?? 'auto';
      final translated = widget.ocr == null
          ? await _client.translate(
              provider,
              key,
              segments,
              source: source,
              target: target,
              context: widget.title,
            )
          : await TranslationCache(widget.ocr!.directory, _client).translate(
              provider,
              key,
              segments,
              source: source,
              target: target,
              context: widget.title,
              cache: !widget.incognito,
            );
      if (mounted && generation == _generation) {
        setState(() {
          _translations = translated;
          _translated = true;
        });
      }
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  String get _textValue => _translated && _translations != null
      ? _translations!.join('\n\n')
      : _document?.text ?? '';
  @override
  void dispose() {
    _generation++;
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        tr(
          context,
          widget.initialText == null ? 'Recognize Text' : 'Selected Text',
        ),
      ),
      actions: [
        IconButton(
          tooltip: tr(context, 'Translate'),
          onPressed:
              _busy || _translating || _document?.text.trim().isEmpty != false
              ? null
              : _translate,
          icon: Icon(
            Icons.translate,
            color: _translated ? Theme.of(context).colorScheme.primary : null,
          ),
        ),
        PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'settings') _settings();
            if (value == 'copy') {
              Clipboard.setData(ClipboardData(text: _textValue));
            }
            if (value == 'regions') setState(() => _overlay = !_overlay);
            if (value == 'bubbles') {
              setState(() => _groupBubbles = !_groupBubbles);
              widget.providers.store.setSetting(
                'ocrGroupBubbles',
                _groupBubbles,
              );
              unawaited(_recognize());
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'settings',
              child: Text(tr(context, 'Translation Providers')),
            ),
            PopupMenuItem(
              value: 'copy',
              enabled: _document != null,
              child: Text(tr(context, 'Copy All')),
            ),
            if (widget.bytes != null)
              PopupMenuItem(
                value: 'regions',
                enabled: _document != null,
                child: Text(tr(context, 'Show Text Regions')),
              ),
            if (widget.bytes != null && widget.detector != null)
              CheckedPopupMenuItem(
                value: 'bubbles',
                checked: _groupBubbles,
                enabled: !_busy && !_translating,
                child: Text(tr(context, 'Group Text by Speech Bubbles')),
              ),
          ],
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
                    onChanged: _busy || _translating
                        ? null
                        : (value) {
                            setState(() => _language = value);
                            unawaited(_recognize());
                          },
                  ),
              ],
            ),
          ),
          if (_busy || _translating) const LinearProgressIndicator(),
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
  Widget _text() => _textValue.trim().isEmpty
      ? const EmptyView(
          title: 'No Text Found',
          message: 'Choose another recognition language or page.',
          icon: Icons.text_fields,
        )
      : SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: SelectionArea(
            child: Text(
              _textValue,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        );
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
              Image.memory(widget.bytes!, fit: BoxFit.fill),
              for (final (index, block) in _document!.blocks.indexed)
                Positioned(
                  left: block.bounds.left * box.maxWidth,
                  top: block.bounds.top * box.maxHeight,
                  width: block.bounds.width * box.maxWidth,
                  height: block.bounds.height * box.maxHeight,
                  child: InkWell(
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        content: SelectableText(
                          _translated ? _translations![index] : block.text,
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Clipboard.setData(
                              ClipboardData(
                                text: _translated
                                    ? _translations![index]
                                    : block.text,
                              ),
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
                    child: _translated
                        ? DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(color: Colors.black26),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: _RegionText(_translations![index]),
                            ),
                          )
                        : DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.blue.withValues(alpha: .16),
                              border: Border.all(
                                color: Colors.blue,
                                width: 1.5,
                              ),
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

class _RegionText extends StatelessWidget {
  const _RegionText(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      var low = 5.0, high = 24.0;
      for (var i = 0; i < 8; i++) {
        final middle = (low + high) / 2;
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(fontSize: middle, height: 1.1),
          ),
          textDirection: Directionality.of(context),
        )..layout(maxWidth: size.maxWidth);
        final fits = painter.height <= size.maxHeight;
        painter.dispose();
        if (fits) {
          low = middle;
        } else {
          high = middle;
        }
      }
      return ClipRect(
        child: Center(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black, fontSize: low, height: 1.1),
          ),
        ),
      );
    },
  );
}
