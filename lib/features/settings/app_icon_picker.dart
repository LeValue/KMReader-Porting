import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';

class AppIconPicker extends StatelessWidget {
  const AppIconPicker({super.key, required this.app, required this.onChanged});
  final AppController app;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          for (final name in ['default', 'classic', 'legacy'])
            Expanded(
              child: Semantics(
                button: true,
                selected:
                    (app.store.setting<String>('appIcon') ?? 'default') == name,
                child: InkWell(
                  onTap: () async {
                    try {
                      await app.setAppIcon(name);
                      onChanged();
                    } catch (error) {
                      if (context.mounted) showError(context, error);
                    }
                  },
                  child: Container(
                    margin: const EdgeInsets.all(4),
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color:
                            (app.store.setting<String>('appIcon') ??
                                    'default') ==
                                name
                            ? Theme.of(context).colorScheme.primary
                            : Colors.transparent,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Image.asset(
                          'assets/app_icons/$name.png',
                          width: 64,
                          height: 64,
                        ),
                        Text(
                          tr(
                            context,
                            name == 'default'
                                ? 'Default'
                                : name == 'classic'
                                ? 'Classic'
                                : 'Legacy',
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
