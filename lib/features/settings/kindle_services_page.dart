import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/kindle/repository.dart';
import '../auth/kindle_login_page.dart';
import 'settings_style.dart';

class KindleServicesPage extends StatefulWidget {
  const KindleServicesPage({
    super.key,
    required this.app,
    required this.repository,
  });
  final AppController app;
  final KindleRepository repository;
  @override
  State<KindleServicesPage> createState() => _KindleServicesPageState();
}

class _KindleServicesPageState extends State<KindleServicesPage> {
  bool _busy = false;
  String? _message;
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      if (mounted) setState(() => _message = 'Operazione completata');
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _toggle(
    String title,
    String key, {
    String? subtitle,
    bool initial = true,
  }) => SwitchListTile.adaptive(
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    value: widget.app.store.setting<bool>(key) ?? initial,
    onChanged: (value) {
      widget.app.store.setSetting(key, value);
      widget.app.settingsChanged();
      setState(() {});
    },
  );

  @override
  Widget build(BuildContext context) {
    final repo = widget.repository;
    return SettingsScaffold(
      title: 'Servizi Kindle',
      body: ListView(
        children: [
          ListTile(
            title: Text(repo.profile.name),
            subtitle: Text('${repo.profile.email}\nAmazon.it'),
          ),
          _toggle(
            'Sincronizza la posizione di lettura',
            'kindleSync:${repo.profile.id}',
          ),
          _toggle(
            'Importa segnalibri e annotazioni da Kindle',
            'kindleAnnotations:${repo.profile.id}',
            subtitle: 'Mostra le annotazioni della stessa edizione. I segnalibri creati in KMReader restano locali.',
          ),
          _toggle(
            'Aggiorna automaticamente la libreria',
            'kindleAutoRefresh:${repo.profile.id}',
          ),
          _toggle(
            'Carica le copertine prima del download',
            'kindleCovers:${repo.profile.id}',
          ),
          if (Platform.isWindows)
            _toggle(
              'Login in finestra separata',
              'kindleIsolatedLogin',
              initial: false,
              subtitle: 'Disattivato: usa Chrome con il tuo profilo abituale. Attivato: acquisizione automatica in una finestra dedicata.',
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('Aggiorna il catalogo'),
            enabled: !_busy && !repo.offline,
            onTap: () => _run(() async {
              await repo.library.refresh(full: true);
              repo.localCatalogChanged();
            }),
          ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Sincronizza adesso'),
            enabled: !_busy && !repo.offline,
            subtitle: Text('${repo.pendingCount} modifiche in attesa'),
            onTap: () => _run(() async {
              await repo.sync();
              await repo.refreshAnnotations();
              if (repo.syncFailure != null) throw StateError(repo.syncFailure!);
            }),
          ),
          ListTile(
            leading: const Icon(Icons.login),
            title: const Text('Ricollega Amazon.it'),
            enabled: !_busy,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => KindleLoginPage(app: widget.app),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services),
            title: const Text('Libera la cache di preparazione'),
            enabled: !_busy,
            subtitle: const Text(
              'Conserva i libri scaricati e la posizione di lettura.',
            ),
            onTap: () => _run(repo.library.clearPreparedCache),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_message!)),
        ],
      ),
    );
  }
}
