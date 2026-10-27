import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../auth/login_page.dart';
import '../offline/downloads_page.dart';
import '../catalog/dashboard.dart';
import '../catalog/history_page.dart';
import 'api_keys_page.dart';
import 'library_editor.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.app, required this.repository});
  final AppController app;
  final Repository repository;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: repository,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          tr(context, 'Servers'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(CupertinoIcons.lock),
                title: Text(tr(context, 'API Keys')),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ApiKeysPage(repository: repository),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(CupertinoIcons.clock),
                title: Text(tr(context, 'History and Statistics')),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => HistoryPage(repository: repository),
                  ),
                ),
              ),
              for (final profile in app.servers)
                ListTile(
                  leading: Icon(
                    CupertinoIcons.tray_2,
                    color: profile.id == repository.profile.id
                        ? Theme.of(context).colorScheme.secondary
                        : null,
                  ),
                  title: Text(profile.name),
                  subtitle: Text('${profile.url}\n${profile.email}'),
                  isThreeLine: true,
                  onTap: () async {
                    try {
                      await app.activate(profile);
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      if (action == 'login' && context.mounted) {
                        Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                LoginPage(app: app, profile: profile),
                          ),
                        );
                      }
                      if (action == 'remove' &&
                          await confirm(
                            context,
                            'Remove Server',
                            'Remove this server and its downloaded files from this device?',
                          )) {
                        try {
                          await app.remove(profile);
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'login',
                        child: Text(tr(context, 'Sign In')),
                      ),
                      PopupMenuItem(
                        value: 'remove',
                        child: Text(tr(context, 'Remove Server')),
                      ),
                    ],
                  ),
                ),
              ListTile(
                leading: const Icon(CupertinoIcons.add_circled),
                title: Text(tr(context, 'Add Server')),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => LoginPage(app: app)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          tr(context, 'Reading and Storage'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(CupertinoIcons.wifi_slash),
                title: Text(tr(context, 'Offline Mode')),
                value: repository.offline,
                onChanged: repository.setOffline,
              ),
              ListTile(
                leading: const Icon(CupertinoIcons.arrow_down_to_line),
                title: Text(tr(context, 'Downloads')),
                trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => DownloadsPage(repository: repository),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(CupertinoIcons.arrow_2_circlepath),
                title: Text(tr(context, 'Sync Progress')),
                subtitle: Text(
                  '${repository.pendingCount} ${tr(context, 'pending')}',
                ),
                onTap: repository.sync,
              ),
              ListTile(
                leading: const Icon(CupertinoIcons.trash),
                title: Text(tr(context, 'Clear Image Cache')),
                subtitle: Text(
                  tr(
                    context,
                    'Downloaded books and reading progress are kept.',
                  ),
                ),
                onTap: () async {
                  if (!await confirm(
                    context,
                    'Clear Image Cache',
                    'Downloaded books and reading progress are kept.',
                  )) {
                    return;
                  }
                  try {
                    await repository.clearImageCache();
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
              if (repository.syncFailure != null)
                ListTile(
                  title: Text(repository.syncFailure!),
                  subtitle: Text(
                    tr(context, 'Your local changes are retained.'),
                  ),
                  trailing: repository.conflicts.isEmpty
                      ? null
                      : PopupMenuButton<String>(
                          onSelected: (value) async {
                            if (value == 'server') {
                              repository.acceptServerProgress();
                            }
                            if (value == 'device' &&
                                await confirm(
                                  context,
                                  'Use Device Progress',
                                  'Replace newer server progress with the progress on this device?',
                                )) {
                              await repository.sync(force: true);
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'server',
                              child: Text(tr(context, 'Use Server Progress')),
                            ),
                            PopupMenuItem(
                              value: 'device',
                              child: Text(tr(context, 'Use Device Progress')),
                            ),
                          ],
                        ),
                ),
              ListTile(
                leading: const Icon(CupertinoIcons.rectangle_grid_1x2),
                title: Text(tr(context, 'Dashboard Sections')),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => _DashboardSettings(repository: repository),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          tr(context, 'Appearance'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(CupertinoIcons.moon),
                title: Text(tr(context, 'Theme')),
                trailing: TextButton.icon(
                  onPressed: () async {
                    final value = await chooseValue(
                      context,
                      title: 'Theme',
                      selected: app.theme,
                      choices: {
                        ThemeMode.system: 'System',
                        ThemeMode.light: 'Light',
                        ThemeMode.dark: 'Dark',
                      },
                    );
                    if (value != null) app.setTheme(value);
                  },
                  icon: const Icon(
                    CupertinoIcons.chevron_up_chevron_down,
                    size: 14,
                  ),
                  label: Text(
                    tr(context, switch (app.theme) {
                      ThemeMode.system => 'System',
                      ThemeMode.light => 'Light',
                      ThemeMode.dark => 'Dark',
                    }),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(CupertinoIcons.globe),
                title: Text(tr(context, 'Language')),
                trailing: TextButton.icon(
                  onPressed: () async {
                    final value = await chooseValue(
                      context,
                      title: 'Language',
                      selected: app.language ?? 'system',
                      choices: {
                        'system': 'System',
                        'en': 'English',
                        'it': 'Italiano',
                        'de': 'Deutsch',
                        'fr': 'Français',
                        'ja': '日本語',
                        'ko': '한국어',
                        'zh_CN': '简体中文',
                        'zh_TW': '繁體中文',
                        'ru': 'Русский',
                        'es': 'Español',
                      },
                    );
                    if (value != null) {
                      app.setLanguage(value == 'system' ? null : value);
                    }
                  },
                  icon: const Icon(
                    CupertinoIcons.chevron_up_chevron_down,
                    size: 14,
                  ),
                  label: Text(
                    tr(
                      context,
                      ({
                            'system': 'System',
                            'en': 'English',
                            'it': 'Italiano',
                            'de': 'Deutsch',
                            'fr': 'Français',
                            'ja': '日本語',
                            'ko': '한국어',
                            'zh_CN': '简体中文',
                            'zh_TW': '繁體中文',
                            'ru': 'Русский',
                            'es': 'Español',
                          })[app.language ?? 'system'] ??
                          'System',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text('Komga', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(CupertinoIcons.info_circle),
                title: Text(tr(context, 'Server Info')),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ServerPage(repository: repository),
                  ),
                ),
              ),
              if (repository.profile.admin)
                ListTile(
                  leading: const Icon(CupertinoIcons.wrench),
                  title: Text(tr(context, 'Library Management')),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => LibraryManagement(repository: repository),
                    ),
                  ),
                ),
              ListTile(
                leading: const Icon(CupertinoIcons.doc_text),
                title: Text(tr(context, 'Licenses')),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'KMReader',
                  applicationVersion: '0.5.0',
                  applicationLegalese: 'Based on KMReader by everpcpc (MIT).\nPorting for Android and Windows.',
                ),
              ),
              ListTile(
                leading: const Icon(CupertinoIcons.square_arrow_right),
                title: Text(tr(context, 'Disconnect')),
                onTap: app.disconnect,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    ),
  );
}

class _DashboardSettings extends StatefulWidget {
  const _DashboardSettings({required this.repository});
  final Repository repository;
  @override
  State<_DashboardSettings> createState() => _DashboardSettingsState();
}

class _DashboardSettingsState extends State<_DashboardSettings> {
  @override
  Widget build(BuildContext context) {
    final key = 'dashboardHidden:${widget.repository.profile.id}';
    final hidden = widget.repository.store.setting<List<dynamic>>(key) ?? [];
    final saved =
        widget.repository.store.setting<List<dynamic>>(
          'dashboardOrder:${widget.repository.profile.id}',
        ) ??
        [];
    final order = [
      ...saved.whereType<String>().where(dashboardSections.contains),
      ...dashboardSections.where((s) => !saved.contains(s)),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Dashboard Sections'))),
      body: ReorderableListView(
        buildDefaultDragHandles: false,
        onReorderItem: (old, target) {
          final updated = [...order];
          updated.insert(target, updated.removeAt(old));
          setState(
            () => widget.repository.store.setSetting(
              'dashboardOrder:${widget.repository.profile.id}',
              updated,
            ),
          );
          widget.repository.catalogChanges.value++;
        },
        children: [
          for (final section in order)
            Row(
              key: ValueKey(section),
              children: [
                Expanded(
                  child: SwitchListTile(
                    title: Text(tr(context, section)),
                    value: !hidden.contains(section),
                    onChanged: (value) {
                      setState(() {
                        if (value) {
                          hidden.remove(section);
                        } else {
                          hidden.add(section);
                        }
                        widget.repository.store.setSetting(key, hidden);
                      });
                      widget.repository.catalogChanges.value++;
                    },
                  ),
                ),
                ReorderableDragStartListener(
                  index: order.indexOf(section),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Tooltip(
                      message: tr(context, 'Reorder'),
                      child: const Icon(CupertinoIcons.line_horizontal_3),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class ServerPage extends StatelessWidget {
  const ServerPage({super.key, required this.repository});
  final Repository repository;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'Server Info'))),
    body: AsyncPanel<dynamic>(
      load: () => repository.get('/actuator/info'),
      builder: (context, value) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            repository.profile.name,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 16),
          ..._rows(object(value)),
        ],
      ),
    ),
  );
  List<Widget> _rows(Json data, [String prefix = '']) => [
    for (final entry in data.entries)
      if (entry.value is Map)
        ..._rows(object(entry.value), '$prefix${entry.key}.')
      else
        ListTile(
          title: Text('$prefix${entry.key}'),
          subtitle: SelectableText('${entry.value}'),
        ),
  ];
}

class LibraryManagement extends StatefulWidget {
  const LibraryManagement({super.key, required this.repository});
  final Repository repository;
  @override
  State<LibraryManagement> createState() => _LibraryManagementState();
}

class _LibraryManagementState extends State<LibraryManagement> {
  int _revision = 0;
  Future<void> _edit([Json? library]) async {
    try {
      Json? fresh;
      if (library != null) {
        fresh = object(
          await widget.repository.api.request(
            '/api/v1/libraries/${Uri.encodeComponent(text(library['id']))}',
          ),
        );
      }
      if (!mounted) return;
      final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              LibraryEditor(repository: widget.repository, library: fresh),
        ),
      );
      if (saved == true && mounted) setState(() => _revision++);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'Library Management')),
      actions: [
        IconButton(
          tooltip: tr(context, 'Add Library'),
          onPressed: widget.repository.offline ? null : _edit,
          icon: const Icon(CupertinoIcons.add),
        ),
      ],
    ),
    body: AsyncPanel<dynamic>(
      key: ValueKey(_revision),
      load: () => widget.repository.get('/api/v1/libraries'),
      builder: (context, data) => ListView(
        children: [
          for (final value in data as List)
            ListTile(
              leading: const Icon(CupertinoIcons.book),
              title: Text(text(object(value)['name'])),
              subtitle: Text(text(object(value)['root'])),
              onTap: () => _edit(object(value)),
              trailing: PopupMenuButton<String>(
                onSelected: (action) async {
                  if (action == 'edit') {
                    await _edit(object(value));
                    return;
                  }
                  if (!await confirm(
                    context,
                    'Library Management',
                    action == 'delete'
                        ? 'Remove this library and its catalog from the server? Files on disk are kept.'
                        : action == 'empty-trash'
                        ? 'Permanently remove unavailable books and their metadata from the catalog?'
                        : 'Run this action on the selected library?',
                  )) {
                    return;
                  }
                  try {
                    await widget.repository.api.request(
                      '/api/v1/libraries/${Uri.encodeComponent(object(value)['id'])}${action == 'delete' ? '' : '/${action == 'deep-scan' ? 'scan' : action}'}',
                      method: action == 'delete' ? 'DELETE' : 'POST',
                      query: action == 'deep-scan' ? {'deep': true} : null,
                    );
                    widget.repository.refreshContent();
                    if (mounted) setState(() => _revision++);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            tr(
                              context,
                              action == 'delete' ? 'Deleted' : 'Task queued',
                            ),
                          ),
                        ),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                itemBuilder: (_) => [
                  for (final e in {
                    'edit': 'Edit Library',
                    'scan': 'Scan',
                    'deep-scan': 'Deep Scan',
                    'analyze': 'Analyze',
                    'metadata/refresh': 'Refresh Metadata',
                    'empty-trash': 'Empty Trash',
                    'delete': 'Delete Library',
                  }.entries)
                    PopupMenuItem(
                      value: e.key,
                      child: Text(tr(context, e.value)),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
