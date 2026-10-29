import 'package:flutter/material.dart';

import '../../core/repository.dart';
import '../../core/store.dart';
import 'preference_controls.dart';

class NetworkSettingsPage extends StatelessWidget {
  const NetworkSettingsPage({super.key, required this.store});
  final LocalStore store;
  @override
  Widget build(BuildContext context) => PreferencePage(
    title: 'Network',
    store: store,
    specs: const [
      PreferenceSpec(
        'requestTimeout',
        'settings.network.request_timeout.label',
        15,
        min: 1,
        max: 600,
        section: 'General',
        caption: 'settings.network.request_timeout.description',
        editor: PreferenceEditor.number,
        unit: 's',
      ),
      PreferenceSpec(
        'downloadTimeout',
        'settings.network.download_timeout.label',
        60,
        min: 1,
        max: 3600,
        caption: 'settings.network.download_timeout.description',
        editor: PreferenceEditor.number,
        unit: 's',
      ),
      PreferenceSpec(
        'authTimeout',
        'settings.network.auth_timeout.label',
        5,
        min: 1,
        max: 600,
        caption: 'settings.network.auth_timeout.description',
        editor: PreferenceEditor.number,
        unit: 's',
      ),
      PreferenceSpec(
        'apiRetryCount',
        'settings.network.api_retry_count.label',
        0,
        min: 0,
        max: 5,
        caption: 'settings.network.api_retry_count.description',
        editor: PreferenceEditor.stepper,
      ),
    ],
  );
}

class RealtimeSettingsPage extends StatelessWidget {
  const RealtimeSettingsPage({super.key, required this.repository});
  final Repository repository;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: repository,
    builder: (context, _) => PreferencePage(
      title: 'Real-time Updates',
      store: repository.store,
      onChanged: (_) => repository.applyEventPreferences(),
      sectionFooters: {
        'Connection': 'Real-time updates allow the app to automatically refresh when content changes on the server.',
        'Auto-refresh': repository.store.setting<bool>('enableSSE') != false
            ? 'When disabled, the dashboard will not automatically refresh when SSE events are received. You can still manually refresh.'
            : 'Enable Real-time Updates above to use this feature.',
        'Notifications': repository.store.setting<bool>('enableSSE') != false
            ? 'When disabled, connection status and task completion messages will not be shown.'
            : 'Enable Real-time Updates above to use this feature.',
      },
      specs: [
        const PreferenceSpec(
          'enableSSE',
          'Real-time Updates',
          true,
          section: 'Connection',
          caption: 'Enable Server-Sent Events for real-time updates',
        ),
        PreferenceSpec(
          'enableSSEAutoRefresh',
          'Auto-refresh Dashboard',
          true,
          enabled: (store) => store.setting<bool>('enableSSE') != false,
          section: 'Auto-refresh',
          caption: 'Automatically refresh dashboard when content changes',
        ),
        PreferenceSpec(
          'enableSSENotify',
          'Show Notifications',
          false,
          enabled: (store) => store.setting<bool>('enableSSE') != false,
          section: 'Notifications',
          caption: 'Show connection status and task completion notifications',
        ),
      ],
    ),
  );
}
