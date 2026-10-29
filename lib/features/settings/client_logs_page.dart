import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/client_log.dart';
import '../../core/file_export.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';

class ClientLogsPage extends StatefulWidget {
  const ClientLogsPage({super.key});
  @override
  State<ClientLogsPage> createState() => _ClientLogsPageState();
}

class _ClientLogsPageState extends State<ClientLogsPage> {
  String _search = '', _level = '';
  bool _exporting = false;
  Future<void> _export() async {
    setState(() => _exporting = true);
    Directory? directory;
    try {
      directory = await Directory.systemTemp.createTemp('kmreader-client-log-');
      final file = File('${directory.path}/kmreader.log');
      await file.writeAsString(ClientLog.instance.exported, flush: true);
      if (mounted) await exportServerLog(file, suggestedName: 'kmreader.log');
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (directory != null) await directory.delete(recursive: true);
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'Logs')),
      actions: [
        IconButton(
          tooltip: tr(context, 'Export'),
          onPressed: _exporting ? null : _export,
          icon: const Icon(Icons.ios_share),
        ),
        IconButton(
          tooltip: tr(context, 'Clear All'),
          onPressed: () async {
            if (await confirm(context, 'Clear All', 'Logs')) {
              ClientLog.instance.clear();
            }
          },
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: tr(context, 'settings.logs.search'),
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (value) =>
                      setState(() => _search = value.toLowerCase()),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: tr(context, 'Level'),
                initialValue: _level,
                onSelected: (value) => setState(() => _level = value),
                itemBuilder: (_) => [
                  for (final value in ['', 'debug', 'info', 'warning', 'error'])
                    CheckedPopupMenuItem(
                      value: value,
                      checked: _level == value,
                      child: Text(value.isEmpty ? tr(context, 'All') : value),
                    ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: ClientLog.instance,
            builder: (context, _) {
              final entries = ClientLog.instance.entries.reversed
                  .where(
                    (entry) =>
                        (_level.isEmpty || entry.level == _level) &&
                        entry.toString().toLowerCase().contains(_search),
                  )
                  .toList();
              return entries.isEmpty
                  ? const EmptyView(title: 'settings.logs.empty')
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) => ListTile(
                        title: SelectableText(entries[index].message),
                        subtitle: Text(
                          '${entries[index].time.toLocal()} · ${entries[index].level} · ${entries[index].category}',
                        ),
                      ),
                    );
            },
          ),
        ),
      ],
    ),
  );
}
