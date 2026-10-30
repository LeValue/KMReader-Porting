import 'settings_style.dart';

import 'package:flutter/material.dart';

import '../../ui/section_scroll_view.dart';
import '../../ui/strings.dart';

class SystemFeaturesPage extends StatelessWidget {
  const SystemFeaturesPage({super.key});
  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: 'System Features',
    body: SectionScrollView(
      padding: const EdgeInsets.all(22),
      children: [
        Text(
          tr(
            context,
            'Handoff, Spotlight and Live Activities require Apple operating systems. They are unavailable on Android and Windows.',
          ),
        ),
      ],
    ),
  );
}
