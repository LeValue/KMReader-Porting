import 'package:flutter/material.dart';

import '../../core/store.dart';
import '../../ui/strings.dart';
import '../reader/reader_ocr.dart';

class RecognitionModelsPage extends StatefulWidget {
  const RecognitionModelsPage({
    super.key,
    required this.store,
    required this.ocr,
  });
  final LocalStore store;
  final ReaderOcr ocr;
  @override
  State<RecognitionModelsPage> createState() => _RecognitionModelsPageState();
}

class _RecognitionModelsPageState extends State<RecognitionModelsPage> {
  late Future<List<String>> _languages;
  @override
  void initState() {
    super.initState();
    _languages = widget.ocr.languages();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'Models')),
      actions: [
        IconButton(
          tooltip: tr(context, 'Refresh'),
          onPressed: () => setState(() => _languages = widget.ocr.languages()),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Card(
          child: Column(
            children: [
              ListTile(
                title: Text(tr(context, 'Detection Model')),
                subtitle: const Text('YOLO11n · ONNX · Apache-2.0'),
              ),
              SwitchListTile(
                title: Text(tr(context, 'Group Text by Comic Bubbles')),
                value: widget.store.setting<bool>('ocrGroupBubbles') == true,
                onChanged: (value) => setState(
                  () => widget.store.setSetting('ocrGroupBubbles', value),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Card(
          child: Column(
            children: [
              ListTile(
                title: Text(tr(context, 'Recognition Model')),
                subtitle: const Text('ML Kit / Windows OCR'),
              ),
              FutureBuilder<List<String>>(
                future: _languages,
                builder: (context, snapshot) => ListTile(
                  title: Text(tr(context, 'Languages')),
                  subtitle: Text(
                    snapshot.hasError
                        ? tr(
                            context,
                            'Install an OCR language pack in your device settings.',
                          )
                        : snapshot.hasData
                        ? snapshot.data!.join(' · ')
                        : '…',
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          tr(
            context,
            'Apple Core ML model packages cannot run on Android or Windows. The portable bubble model is included; recognition uses the installed system language packs.',
          ),
        ),
      ],
    ),
  );
}
