import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/updates/app_updates.dart';
import '../../ui/strings.dart';

class AppUpdatePage extends StatefulWidget {
  const AppUpdatePage({super.key, this.updates});
  final AppUpdates? updates;
  @override
  State<AppUpdatePage> createState() => _AppUpdatePageState();
}

class _AppUpdatePageState extends State<AppUpdatePage> {
  late final service = widget.updates ?? AppUpdates();
  AppUpdate? update;
  File? package;
  bool busy = false, checked = false, restarting = false;
  double? progress;
  String? message;
  @override
  void dispose() {
    service.close();
    super.dispose();
  }

  Future<void> check() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final previousFailure = await service.previousInstallFailed();
      final result = await service.check(
        Platform.isAndroid
            ? 'android'
            : Platform.isWindows
            ? 'windows'
            : 'other',
      );
      if (mounted) {
        setState(() {
          update = result;
          message = previousFailure
              ? tr(
                  context,
                  'The previous update failed. Your application files were restored; you can retry.',
                )
              : null;
          checked = true;
          package = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => message = tr(
            context,
            'Unable to update. Check your connection and available storage, then retry.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> install() async {
    final release = update;
    if (release == null) return;
    setState(() {
      busy = true;
      message = null;
      progress = null;
    });
    try {
      package = await service.download(
        release,
        await service.storageDirectory(),
        (done, total) {
          if (mounted) setState(() => progress = done / total);
        },
      );
      if (!mounted) return;
      final launched = await service.install(release, package!);
      if (!mounted) return;
      if (Platform.isWindows && launched) {
        setState(() => restarting = true);
        await service.requestRestart();
      } else {
        setState(
          () => message = tr(
            context,
            launched ? 'Confirm the update in the system installer.' : 'Allow updates from this app in system settings, then tap Install update again.',
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => message = Platform.isWindows && restarting
              ? tr(context, 'Close the app to finish the update.')
              : tr(
                  context,
                  'Unable to update. Check your connection and available storage, then retry.',
                ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'App updates'))),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          tr(
            context,
            'Updates are downloaded from the official public releases. Accounts, books and reading progress are kept.',
          ),
        ),
        const SizedBox(height: 16),
        if (Platform.isAndroid)
          Text(
            tr(
              context,
              'Android requires confirmation in the system installer.',
            ),
          ),
        if (Platform.isWindows)
          Text(
            tr(
              context,
              'The app will close, update and reopen. Previous application files are backed up.',
            ),
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy || restarting ? null : check,
          child: Text(tr(context, 'Check for updates')),
        ),
        if (checked && update == null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(tr(context, 'No newer update is available.')),
          ),
        if (update case final release?) ...[
          const SizedBox(height: 16),
          Text(
            '${release.version} (${release.build}) — ${(release.size / 1024 / 1024).ceil()} MB',
          ),
          FilledButton.icon(
            onPressed: busy || restarting ? null : install,
            icon: const Icon(Icons.system_update),
            label: Text(
              tr(
                context,
                Platform.isWindows ? 'Restart and update' : 'Install update',
              ),
            ),
          ),
        ],
        if (busy)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: LinearProgressIndicator(value: progress),
          ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(message!),
          ),
      ],
    ),
  );
}
