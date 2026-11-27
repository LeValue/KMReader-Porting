import 'settings_style.dart';

import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/download_notifications.dart';
import '../../core/system_library_index.dart';
import '../../ui/common.dart';
import '../../ui/section_scroll_view.dart';
import '../../ui/strings.dart';

class SystemFeaturesPage extends StatefulWidget {
  const SystemFeaturesPage({super.key, required this.app});
  final AppController app;

  @override
  State<SystemFeaturesPage> createState() => _SystemFeaturesPageState();
}

class _SystemFeaturesPageState extends State<SystemFeaturesPage> {
  bool _asking = false;
  bool _indexing = false;

  Future<void> _index(bool enabled) async {
    final app = widget.app;
    setState(() => _indexing = true);
    app.store.setSetting(SystemLibraryIndex.setting, enabled);
    try {
      await app.backgroundDownloads.libraryIndex.refresh();
    } catch (_) {
      if (enabled) {
        app.store.setSetting(SystemLibraryIndex.setting, false);
        await app.backgroundDownloads.libraryIndex.refresh().catchError(
          (Object _) {},
        );
      }
      if (mounted) showError(context, 'Could not update system search.');
    } finally {
      if (mounted) setState(() => _indexing = false);
    }
  }

  Future<void> _notifications(bool enabled) async {
    setState(() => _asking = true);
    try {
      if (enabled && !await DownloadNotifications.enable()) {
        if (mounted) {
          showError(context, 'Allow notifications in your system settings.');
        }
        return;
      }
      widget.app.store.setSetting(DownloadNotifications.setting, enabled);
    } catch (failure) {
      if (mounted) showError(context, failure);
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: 'System Features',
    body: SectionScrollView(
      padding: const EdgeInsets.all(22),
      children: [
        if (DownloadNotifications.supported)
          SwitchListTile.adaptive(
            value:
                widget.app.store.setting<bool>(DownloadNotifications.setting) ==
                true,
            onChanged: _asking ? null : _notifications,
            title: Text(tr(context, 'Download Notifications')),
            subtitle: Text(
              tr(context, 'Show when a download completes or needs attention.'),
            ),
          ),
        if (widget.app.backgroundDownloads.libraryIndex.supported)
          SwitchListTile.adaptive(
            value:
                widget.app.store.setting<bool>(SystemLibraryIndex.setting) ==
                true,
            onChanged: _indexing ? null : _index,
            title: Text(tr(context, 'Find Downloads in System Search')),
            subtitle: Text(
              tr(
                context,
                'Share downloaded book titles with system search. Protected profiles and private sessions are excluded.',
              ),
            ),
          ),
      ],
    ),
  );
}
