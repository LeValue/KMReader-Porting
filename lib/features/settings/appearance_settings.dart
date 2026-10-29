import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/repository.dart';
import 'app_icon_picker.dart';
import 'preference_controls.dart';
import 'settings_style.dart';

class AppearanceSettings extends StatelessWidget {
  const AppearanceSettings({
    super.key,
    required this.app,
    required this.repository,
  });
  final AppController app;
  final Repository repository;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      PreferencePage(
        title: 'Appearance',
        embedded: true,
        store: app.store,
        specs: [
          PreferenceSpec(
            'language',
            'settings.appearance.language.change',
            'system',
            section: 'settings.appearance.language',
            readValue: (_) => app.language ?? 'system',
            writeValue: (_, value) =>
                app.setLanguage(value == 'system' ? null : value as String),
            choices: const {
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
          ),
        ],
      ),
      const SettingsHeading('App Icon'),
      AppIconPicker(app: app, onChanged: repository.changed),
      const SizedBox(height: 28),
      PreferencePage(
        title: 'Appearance',
        embedded: true,
        store: app.store,
        onChanged: (_) => app.settingsChanged(),
        specs: [
          PreferenceSpec(
            'appColorScheme',
            'settings.appearance.colorScheme.title',
            ThemeMode.system,
            section: 'settings.appearance.theme',
            readValue: (_) => app.theme,
            writeValue: (_, value) => app.setTheme(value as ThemeMode),
            choices: const {
              ThemeMode.system: 'System',
              ThemeMode.light: 'Light',
              ThemeMode.dark: 'Dark',
            },
          ),
          const PreferenceSpec(
            'useClassicPadNavigation',
            'settings.appearance.classicNavigation.title',
            true,
            section: 'settings.appearance.navigation',
            caption: 'settings.appearance.classicNavigation.caption',
          ),
          const PreferenceSpec(
            'privacyProtection',
            'settings.appearance.privacyProtection.title',
            false,
            section: 'settings.appearance.privacy',
            caption: 'settings.privacy.port.caption',
          ),
        ],
      ),
    ],
  );
}
