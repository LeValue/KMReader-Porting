import 'package:flutter/material.dart';

import '../../core/app_version.dart';
import '../../core/external_links.dart';
import '../../ui/strings.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'About'))),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Image.asset('assets/logo.png', height: 96),
        const SizedBox(height: 16),
        const Center(child: Text('KMReader $appVersion ($appBuildNumber)')),
        const SizedBox(height: 24),
        Card(
          child: Column(
            children: [
              for (final entry in const {
                'User Guide': 'https://kmworks.date/reader/intro/',
                'GitHub': 'https://github.com/LeValue/KMReader-Porting',
                'Discord': 'https://discord.gg/WQtE6VhjpP',
              }.entries)
                ListTile(
                  title: Text(tr(context, entry.key)),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => openExternalWebLink(Uri.parse(entry.value)),
                ),
              ListTile(
                title: Text(tr(context, 'Open Source Licenses')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'KMReader',
                  applicationVersion: '$appVersion ($appBuildNumber)',
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
