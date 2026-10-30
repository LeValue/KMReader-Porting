import 'dart:io';

import 'package:flutter/material.dart';

import '../reader/reader_ocr.dart';
import 'recognition_models_page.dart';

import '../../core/translation.dart';
import '../../ui/common.dart';
import '../../ui/section_scroll_view.dart';
import '../../ui/strings.dart';
import '../reader/reader_display.dart';
import 'preference_controls.dart';
import '../../ui/wheel_scroll.dart';

const translationLanguages = {
  'en': 'English',
  'it': 'Italiano',
  'de': 'Deutsch',
  'fr': 'Français',
  'es': 'Español',
  'ja': '日本語',
  'ko': '한국어',
  'zh': '中文',
  'ru': 'Русский',
  'pt': 'Português',
  'ar': 'العربية',
  'th': 'ไทย',
  'vi': 'Tiếng Việt',
  'hi': 'हिन्दी',
  'tr': 'Türkçe',
  'pl': 'Polski',
  'nl': 'Nederlands',
  'sv': 'Svenska',
  'da': 'Dansk',
  'fi': 'Suomi',
  'no': 'Norsk',
  'cs': 'Čeština',
  'hu': 'Magyar',
  'ro': 'Română',
  'el': 'Ελληνικά',
  'he': 'עברית',
  'id': 'Bahasa Indonesia',
  'ms': 'Bahasa Melayu',
  'uk': 'Українська',
  'bg': 'Български',
  'hr': 'Hrvatski',
  'sk': 'Slovenčina',
  'sl': 'Slovenščina',
  'et': 'Eesti',
  'lv': 'Latviešu',
  'lt': 'Lietuvių',
  'mt': 'Malti',
  'ga': 'Gaeilge',
  'cy': 'Cymraeg',
  'is': 'Íslenska',
};

class TranslationSettingsPage extends StatefulWidget {
  const TranslationSettingsPage({
    super.key,
    required this.providers,
    this.immersive = false,
    this.ocr,
  });
  final TranslationProviders providers;
  final bool immersive;
  final ReaderOcr? ocr;
  @override
  State<TranslationSettingsPage> createState() =>
      _TranslationSettingsPageState();
}

class _TranslationSettingsPageState extends State<TranslationSettingsPage> {
  Future<void> _edit([TranslationProvider? provider]) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => widget.immersive
            ? ReaderDisplay(
                child: _ProviderEditor(
                  providers: widget.providers,
                  provider: provider,
                ),
              )
            : _ProviderEditor(providers: widget.providers, provider: provider),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final providers = widget.providers, values = providers.values;
    final target = providers.store.setting<String>('translationTarget') ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Translation Providers')),
        actions: [
          IconButton(
            tooltip: tr(context, 'Add'),
            onPressed: () => _edit(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              tr(
                context,
                'Text is sent to the provider you select when you request a translation.',
              ),
            ),
            PreferencePage(
              title: 'Manga Translation',
              embedded: true,
              store: providers.store,
              specs: const [
                PreferenceSpec(
                  'translationSource',
                  'Default Source Language',
                  'auto',
                  choices: {'auto': 'Automatic', ...translationLanguages},
                ),
                PreferenceSpec(
                  'translationTextDirection',
                  'Text Direction',
                  'auto',
                  choices: {
                    'auto': 'Automatic',
                    'horizontal': 'Horizontal',
                    'vertical': 'Vertical',
                  },
                ),
                PreferenceSpec(
                  'translationIncludeMetadata',
                  'Include Comic Metadata',
                  false,
                  caption: 'Add series, chapter, authors, and genres to the prompt to improve names and tone.',
                ),
                PreferenceSpec('translationShow', 'Show Translation', true),
                PreferenceSpec(
                  'ocrGroupBubbles',
                  'Group Text by Comic Bubbles',
                  false,
                ),
              ],
            ),
            if (widget.ocr != null) ...[
              ListTile(
                title: Text(tr(context, 'Models')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RecognitionModelsPage(
                      store: providers.store,
                      ocr: widget.ocr!,
                    ),
                  ),
                ),
              ),
              ListTile(
                title: Text(tr(context, 'Clear Translation Cache')),
                onTap: () async {
                  if (!await confirm(
                    context,
                    'Clear Translation Cache',
                    'Clear Translation Cache',
                  )) {
                    return;
                  }
                  final directory = Directory(
                    '${widget.ocr!.directory.path}/translations',
                  );
                  try {
                    if (await directory.exists()) {
                      await directory.delete(recursive: true);
                    }
                  } catch (error) {
                    if (context.mounted) showError(context, error);
                  }
                },
              ),
            ],
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              initialValue:
                  target.isEmpty || translationLanguages.containsKey(target)
                  ? target
                  : 'en',
              decoration: InputDecoration(
                labelText: tr(context, 'Target Language'),
              ),
              items: [
                DropdownMenuItem(
                  value: '',
                  child: Text(tr(context, 'System Language')),
                ),
                for (final entry in translationLanguages.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) {
                providers.store.setSetting('translationTarget', value);
                setState(() {});
              },
            ),
            const SizedBox(height: 20),
            if (values.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  tr(
                    context,
                    'Add an OpenAI-compatible provider or a local translation server.',
                  ),
                ),
              ),
            for (final provider in values)
              Card(
                child: ListTile(
                  leading: Icon(
                    providers.active?.id == provider.id
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                  ),
                  title: Text(provider.name),
                  subtitle: Text('${provider.base}\n${provider.model}'),
                  isThreeLine: true,
                  onTap: () {
                    providers.select(provider);
                    setState(() {});
                  },
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      if (action == 'edit') {
                        await _edit(provider);
                        return;
                      }
                      if (await confirm(
                        context,
                        'Remove Provider',
                        'Remove this provider and its saved API key?',
                      )) {
                        try {
                          await providers.remove(provider);
                          if (mounted) setState(() {});
                        } catch (error) {
                          if (context.mounted) showError(context, error);
                        }
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'edit',
                        child: Text(tr(context, 'Edit')),
                      ),
                      PopupMenuItem(
                        value: 'remove',
                        child: Text(tr(context, 'Remove')),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add),
              label: Text(tr(context, 'Add Provider')),
            ),
          ],
        ).withWheelScrolling(),
      ),
    );
  }
}

class _ProviderEditor extends StatefulWidget {
  const _ProviderEditor({required this.providers, this.provider});
  final TranslationProviders providers;
  final TranslationProvider? provider;
  @override
  State<_ProviderEditor> createState() => _ProviderEditorState();
}

class _ProviderEditorState extends State<_ProviderEditor> {
  late final _name = TextEditingController(
    text: widget.provider?.name ?? 'OpenRouter',
  );
  late final _base = TextEditingController(
    text: widget.provider?.base ?? 'https://openrouter.ai/api/v1',
  );
  late final _model = TextEditingController(text: widget.provider?.model ?? '');
  final _key = TextEditingController(), _form = GlobalKey<FormState>();
  final _client = TranslationClient();
  bool _busy = false, _clearKey = false;
  String? _error;
  @override
  void dispose() {
    _client.close();
    for (final controller in [_name, _base, _model, _key]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _models() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final provider = TranslationProvider(
        id: 'probe',
        name: _name.text,
        base: _base.text,
        model: _model.text,
      );
      final key = _clearKey
          ? null
          : _key.text.isNotEmpty
          ? _key.text
          : widget.provider == null
          ? null
          : await widget.providers.key(widget.provider!.id);
      final models = await _client.models(provider, key);
      if (!mounted) return;
      var query = '';
      final chosen = await showDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) {
            final visible = models
                .where(
                  (m) => '${m['name']} ${m['id']}'.toLowerCase().contains(
                    query.toLowerCase(),
                  ),
                )
                .toList();
            return AlertDialog(
              title: Text(tr(context, 'Choose Model')),
              content: SizedBox(
                width: 600,
                height: MediaQuery.sizeOf(context).height * .6,
                child: Column(
                  children: [
                    TextField(
                      decoration: InputDecoration(
                        labelText: tr(context, 'Search'),
                      ),
                      onChanged: (value) => update(() => query = value),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, index) => ListTile(
                          title: Text(visible[index]['name']),
                          subtitle: Text(visible[index]['id']),
                          onTap: () =>
                              Navigator.pop(context, visible[index]['id']),
                        ),
                      ).withWheelScrolling(),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
      if (chosen != null) _model.text = chosen;
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.providers.save(
        original: widget.provider,
        name: _name.text,
        base: _base.text,
        model: _model.text,
        apiKey: _key.text,
        clearKey: _clearKey,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        tr(context, widget.provider == null ? 'Add Provider' : 'Edit Provider'),
      ),
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SectionScrollView(
            padding: const EdgeInsets.all(24),
            children: [
              Form(
                key: _form,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _name,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        labelText: tr(context, 'Name'),
                      ),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? tr(context, 'Required')
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _base,
                      enabled: !_busy,
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                      decoration: InputDecoration(
                        labelText: tr(context, 'API Base URL'),
                        hintText: 'https://openrouter.ai/api/v1',
                      ),
                      validator: (v) {
                        try {
                          TranslationProvider.parse({'base': v});
                          return null;
                        } catch (_) {
                          return tr(
                            context,
                            'Enter a valid HTTP or HTTPS address.',
                          );
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _key,
                      enabled: !_busy && !_clearKey,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: tr(context, 'API Key'),
                        helperText: tr(
                          context,
                          widget.provider == null
                              ? 'Optional for local providers'
                              : 'Leave blank to keep the saved key',
                        ),
                      ),
                    ),
                    if (widget.provider != null)
                      SwitchListTile(
                        title: Text(tr(context, 'Remove Saved Key')),
                        value: _clearKey,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _clearKey = v),
                      ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _model,
                      enabled: !_busy,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: tr(context, 'Model'),
                      ),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? tr(context, 'Required')
                          : null,
                    ),
                    TextButton.icon(
                      onPressed: _busy ? null : _models,
                      icon: const Icon(Icons.list),
                      label: Text(tr(context, 'Load Models')),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (_busy) const LinearProgressIndicator(),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _save,
                      child: Text(tr(context, 'Save')),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
