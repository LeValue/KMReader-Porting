import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/models.dart';
import '../../core/file_export.dart';
import '../../core/repository.dart';
import '../../core/server_management.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';

class ServerManagementPage extends StatelessWidget {
  const ServerManagementPage({super.key, required this.repository});
  final Repository repository;
  @override
  Widget build(BuildContext context) {
    final management = ServerManagement(repository);
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr(context, 'Server Management')),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              for (final title in [
                'Tasks',
                'Scheduled Tasks',
                'Sessions',
                'Logs',
              ])
                Tab(text: tr(context, title)),
            ],
          ),
          actions: [
            PopupMenuButton<String>(
              onSelected: (_) async {
                if (!await confirm(
                  context,
                  'Shut Down Server',
                  'The server will stop. Start it again on its host to reconnect.',
                )) {
                  return;
                }
                try {
                  await management.shutdown();
                } catch (error) {
                  if (context.mounted) showError(context, error);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'shutdown',
                  enabled: !repository.offline,
                  child: Text(tr(context, 'Shut Down Server')),
                ),
              ],
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: TabBarView(
            children: [
              _Tasks(management: management),
              _Scheduled(management: management),
              _Sessions(management: management),
              _Logs(management: management),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tasks extends StatefulWidget {
  const _Tasks({required this.management});
  final ServerManagement management;
  @override
  State<_Tasks> createState() => _TasksState();
}

class _TasksState extends State<_Tasks> {
  int _revision = 0;
  bool _busy = false;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      ValueListenableBuilder<Json>(
        valueListenable: widget.management.repository.taskQueueStatus,
        builder: (context, status, _) => Column(
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr(context, 'Task Queue')),
              trailing: Text(
                status.containsKey('count')
                    ? '${integer(status['count'])}'
                    : '—',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            for (final entry in object(status['countByType']).entries)
              ListTile(
                title: Text(entry.key),
                trailing: Text('${entry.value}'),
              ),
            if (widget.management.repository.offline)
              Text(tr(context, 'Offline snapshot')),
            FilledButton.tonalIcon(
              onPressed:
                  _busy ||
                      widget.management.repository.offline ||
                      integer(status['count']) == 0
                  ? null
                  : () async {
                      if (!await confirm(
                        context,
                        'Cancel All Tasks',
                        'Queued server tasks will be cancelled. Library files are kept.',
                      )) {
                        return;
                      }
                      if (!mounted) return;
                      setState(() => _busy = true);
                      try {
                        await widget.management.cancelTasks();
                      } catch (error) {
                        if (context.mounted) showError(context, error);
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
              icon: const Icon(Icons.cancel_outlined),
              label: Text(tr(context, 'Cancel All Tasks')),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(tr(context, 'Task Metrics')),
        trailing: IconButton(
          tooltip: tr(context, 'Refresh'),
          onPressed: () => setState(() => _revision++),
          icon: const Icon(Icons.refresh),
        ),
      ),
      AsyncPanel<List<Json>>(
        revision: _revision,
        load: widget.management.taskMetrics,
        builder: (context, metrics) => Column(
          children: [
            if (metrics.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  tr(context, 'No task metrics are reported by this server.'),
                ),
              ),
            for (final metric in metrics)
              ListTile(
                title: Text(text(metric['type'])),
                subtitle: Text(
                  '${tr(context, 'Total Time')}: ${(metric['total'] as num).toStringAsFixed(1)} s · ${tr(context, 'Longest')}: ${(metric['max'] as num).toStringAsFixed(1)} s',
                ),
                trailing: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${(metric['count'] as num).round()} ${tr(context, 'Runs')}',
                    ),
                    Text(
                      '${(metric['failures'] as num).round()} ${tr(context, 'Failures')}',
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

class _Scheduled extends StatefulWidget {
  const _Scheduled({required this.management});
  final ServerManagement management;
  @override
  State<_Scheduled> createState() => _ScheduledState();
}

class _ScheduledState extends State<_Scheduled> {
  int _revision = 0;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Align(
        alignment: Alignment.centerRight,
        child: IconButton(
          tooltip: tr(context, 'Refresh'),
          icon: const Icon(Icons.refresh),
          onPressed: () => setState(() => _revision++),
        ),
      ),
      Expanded(
        child: AsyncPanel<List<Json>>(
          revision: _revision,
          load: widget.management.scheduledTasks,
          builder: (context, tasks) => tasks.isEmpty
              ? const EmptyView(
                  title: 'No Tasks',
                  message: 'The server has no scheduled tasks.',
                  icon: Icons.schedule,
                )
              : ListView.separated(
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    final interval = task['interval'] as num?;
                    return ListTile(
                      leading: const Icon(Icons.schedule),
                      title: SelectableText(
                        text(
                          object(task['runnable'])['target'],
                          text(task['name']),
                        ),
                      ),
                      subtitle: Text(
                        task['expression'] != null
                            ? text(task['expression'])
                            : interval == null
                            ? tr(context, text(task['group']))
                            : '${tr(context, 'Interval')}: ${Duration(milliseconds: interval.round())}',
                      ),
                    );
                  },
                ),
        ),
      ),
    ],
  );
}

class _Sessions extends StatefulWidget {
  const _Sessions({required this.management});
  final ServerManagement management;
  @override
  State<_Sessions> createState() => _SessionsState();
}

class _SessionsState extends State<_Sessions> {
  int _revision = 0;
  String? _busy;
  String _date(String value) {
    final date = DateTime.tryParse(value);
    return date == null
        ? value
        : DateFormat.yMd().add_Hm().format(date.toLocal());
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Align(
        alignment: Alignment.centerRight,
        child: IconButton(
          tooltip: tr(context, 'Refresh'),
          icon: const Icon(Icons.refresh),
          onPressed: () => setState(() => _revision++),
        ),
      ),
      Expanded(
        child: AsyncPanel<({List<Json> sessions, bool ownOnly})>(
          revision: _revision,
          load: widget.management.sessions,
          builder: (context, result) => ListView(
            children: [
              if (result.ownOnly)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    tr(context, 'This server exposes only your sessions.'),
                  ),
                ),
              if (result.sessions.isEmpty)
                const EmptyView(
                  title: 'No Sessions',
                  message: 'There are no active server sessions.',
                  icon: Icons.people_outline,
                ),
              for (final session in result.sessions)
                ListTile(
                  isThreeLine: true,
                  leading: Icon(
                    session['expired'] == true
                        ? Icons.timer_off_outlined
                        : Icons.person_outline,
                  ),
                  title: Text(
                    text(session['id']),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${tr(context, 'Created')}: ${_date(text(session['creationTime']))}\n${tr(context, 'Last Active')}: ${_date(text(session['lastAccessedTime']))}',
                  ),
                  trailing: IconButton(
                    tooltip: tr(context, 'Revoke Session'),
                    icon: _busy == session['id']
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.logout),
                    onPressed:
                        _busy != null || widget.management.repository.offline
                        ? null
                        : () async {
                            if (!await confirm(
                              context,
                              'Revoke Session',
                              'The selected session will need to sign in again.',
                            )) {
                              return;
                            }
                            if (!mounted) return;
                            setState(() => _busy = text(session['id']));
                            try {
                              await widget.management.revokeSession(
                                text(session['id']),
                              );
                              if (mounted) setState(() => _revision++);
                            } catch (error) {
                              if (context.mounted) showError(context, error);
                            } finally {
                              if (mounted) setState(() => _busy = null);
                            }
                          },
                  ),
                ),
            ],
          ),
        ),
      ),
    ],
  );
}

class _Logs extends StatefulWidget {
  const _Logs({required this.management});
  final ServerManagement management;
  @override
  State<_Logs> createState() => _LogsState();
}

class _LogsState extends State<_Logs> {
  int _revision = 0;
  bool _exporting = false;

  Future<void> _export() async {
    setState(() => _exporting = true);
    Directory? temporary;
    try {
      temporary = await Directory.systemTemp.createTemp('kmreader-log-export-');
      final file = File('${temporary.path}/komga-server.log');
      await widget.management.downloadLog(file, cancelled: () => !mounted);
      if (mounted) await exportServerLog(file);
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (temporary != null) {
        try {
          await temporary.delete(recursive: true);
        } on FileSystemException {
          // System cache cleanup can remove this temporary directory first.
        }
      }
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          IconButton(
            tooltip: tr(context, 'Download Log'),
            onPressed: _exporting || widget.management.repository.offline
                ? null
                : _export,
            icon: _exporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_alt),
          ),
          IconButton(
            tooltip: tr(context, 'Refresh'),
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _revision++),
          ),
        ],
      ),
      Expanded(
        child: AsyncPanel<String>(
          revision: _revision,
          load: widget.management.recentLog,
          builder: (context, log) => Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: log)),
                  icon: const Icon(Icons.copy),
                  label: Text(tr(context, 'Copy')),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    log,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}
