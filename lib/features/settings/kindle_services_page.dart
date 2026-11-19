import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/kindle/repository.dart';
import '../../core/models.dart';
import '../../ui/common.dart';
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
  Future<void> _run(
    Future<void> Function() action, {
    String? Function()? result,
  }) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      if (mounted) {
        setState(
          () => _message = result == null ? 'Operazione completata' : result(),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _conflict(String id, Json conflict) {
    final repo = widget.repository;
    final title = repo.readingConflictTitle(id);
    return ListTile(
      leading: const Icon(Icons.sync_problem),
      title: Text(title.isEmpty ? 'Libro Kindle' : title),
      subtitle: const Text(
        'La posizione Kindle è diversa da quella salvata su questo dispositivo.',
      ),
      trailing: PopupMenuButton<bool>(
        tooltip: 'Scegli la posizione di lettura',
        enabled: !_busy,
        onSelected: (kindle) async {
          if (kindle) {
            final accepted = repo.useKindlePosition(id, conflict);
            setState(() {
              _message = accepted
                  ? 'La posizione Kindle verrà applicata quando riapri il libro.'
                  : 'La posizione è cambiata. Sincronizza di nuovo e riprova.';
            });
            return;
          }
          final approved = await confirm(
            context,
            'Invia la posizione di questo dispositivo',
            'Sostituire la posizione Kindle di questo libro? La modifica si sincronizzerà con gli altri dispositivi.',
          );
          if (!approved || !mounted) return;
          var sent = false;
          await _run(
            () async => sent = await repo.sendDevicePosition(id, conflict),
            result: () => sent
                ? 'Posizione inviata a Kindle.'
                : 'Invio non confermato. La posizione locale resta in attesa.',
          );
        },
        itemBuilder: (context) => [
          const PopupMenuItem(value: true, child: Text('Usa posizione Kindle')),
          PopupMenuItem(
            value: false,
            enabled: !repo.offline,
            child: const Text('Invia posizione di questo dispositivo'),
          ),
        ],
      ),
    );
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
      body: ListenableBuilder(
        listenable: repo,
        builder: (context, _) => ListView(
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
              'Sincronizza segnalibri e annotazioni Kindle',
              'kindleAnnotations:${repo.profile.id}',
              subtitle: 'Mostra le annotazioni Kindle della stessa edizione e invia i nuovi segnalibri, le note e le evidenziazioni dei documenti personali.',
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
              subtitle: Text(
                repo.pendingCount == 1
                    ? '1 modifica in attesa'
                    : '${repo.pendingCount} modifiche in attesa',
              ),
              onTap: () => _run(
                () async {
                  await repo.sync();
                  await repo.refreshAnnotations();
                },
                result: () => repo.readingConflicts.isNotEmpty
                    ? null
                    : repo.syncFailure ??
                          (repo.pendingCount == 0
                              ? 'Sincronizzazione completata'
                              : 'Sincronizzazione in attesa'),
              ),
            ),
            for (final entry in repo.readingConflicts.entries)
              _conflict(entry.key, entry.value),
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
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_message!),
              ),
          ],
        ),
      ),
    );
  }
}
