import 'package:flutter/material.dart';

import '../../ui/strings.dart';

class SystemFeaturesPage extends StatelessWidget {
  const SystemFeaturesPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'System Features'))),
    body: ListView(
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
