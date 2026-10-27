import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../auth/login_page.dart';
import '../offline/downloads_page.dart';
import 'api_keys_page.dart';

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
                trailing: DropdownButton<ThemeMode>(
                  value: app.theme,
                  underline: const SizedBox(),
                  onChanged: (v) {
                    if (v != null) app.setTheme(v);
                  },
                  items: [
                    for (final mode in ThemeMode.values)
                      DropdownMenuItem(
                        value: mode,
                        child: Text(
                          tr(context, switch (mode) {
                            ThemeMode.system => 'System',
                            ThemeMode.light => 'Light',
                            ThemeMode.dark => 'Dark',
                          }),
                        ),
                      ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(CupertinoIcons.globe),
                title: Text(tr(context, 'Language')),
                trailing: DropdownButton<String>(
                  value: app.language ?? 'system',
                  underline: const SizedBox(),
                  onChanged: (v) => app.setLanguage(v == 'system' ? null : v),
                  items: [
                    DropdownMenuItem(
                      value: 'system',
                      child: Text(tr(context, 'System')),
                    ),
                    for (final e in {
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
                    }.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
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
                  applicationVersion: '0.1.0',
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
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Dashboard Sections'))),
      body: ListView(
        children: [
          for (final section in [
            'dashboard.keepReading',
            'dashboard.onDeck',
            'dashboard.recentlyAddedBooks',
            'dashboard.recentlyAddedSeries',
            'dashboard.recentlyUpdatedSeries',
          ])
            SwitchListTile(
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
                widget.repository.refreshContent();
              },
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
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'Library Management'))),
    body: AsyncPanel<dynamic>(
      load: () => widget.repository.get('/api/v1/libraries'),
      builder: (context, data) => ListView(
        children: [
          for (final value in data as List)
            ListTile(
              leading: const Icon(CupertinoIcons.book),
              title: Text(text(object(value)['name'])),
              subtitle: Text(text(object(value)['root'])),
              trailing: PopupMenuButton<String>(
                onSelected: (action) async {
                  if (!await confirm(
                    context,
                    'Library Management',
                    'Run this action on the selected library?',
                  )) {
                    return;
                  }
                  try {
                    await widget.repository.api.request(
                      '/api/v1/libraries/${Uri.encodeComponent(object(value)['id'])}/$action',
                      method: 'POST',
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(tr(context, 'Task queued'))),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                itemBuilder: (_) => [
                  for (final e in {
                    'scan': 'Scan',
                    'analyze': 'Analyze',
                    'metadata/refresh': 'Refresh Metadata',
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
