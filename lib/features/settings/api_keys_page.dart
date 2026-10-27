import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../catalog/list_actions.dart';

class ApiKeysPage extends StatefulWidget {
  const ApiKeysPage({super.key, required this.repository});
  final Repository repository;
  @override
  State<ApiKeysPage> createState() => _ApiKeysPageState();
}

class _ApiKeysPageState extends State<ApiKeysPage> {
  int _revision = 0;
  bool _busy = false;
  Future<void> _create() async {
    final comment = await askName(context, 'Create API Key');
    if (comment == null || _busy) return;
    setState(() => _busy = true);
    try {
      final result = object(
        await widget.repository.api.request(
          '/api/v2/users/me/api-keys',
          method: 'POST',
          body: {'comment': comment},
        ),
      );
      if (!mounted) return;
      setState(() => _revision++);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr(context, 'API Key')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr(context, 'Copy this key now. It will not be shown again.'),
              ),
              const SizedBox(height: 16),
              SelectableText(text(result['key'])),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: text(result['key']))),
              child: Text(tr(context, 'Copy')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr(context, 'Done')),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'API Keys')),
      actions: [
        IconButton(
          tooltip: tr(context, 'Create API Key'),
          onPressed: _busy ? null : _create,
          icon: const Icon(CupertinoIcons.add),
        ),
      ],
    ),
    body: AsyncPanel<dynamic>(
      key: ValueKey(_revision),
      load: () => widget.repository.api.request('/api/v2/users/me/api-keys'),
      builder: (context, data) => ListView(
        children: [
          for (final value in data as List)
            ListTile(
              leading: const Icon(CupertinoIcons.lock),
              title: Text(text(object(value)['comment'])),
              subtitle: Text(
                object(value)['id'] == widget.repository.profile.apiKeyId
                    ? tr(context, 'Current Device')
                    : text(object(value)['createdDate']),
              ),
              trailing: IconButton(
                tooltip: tr(context, 'Revoke API Key'),
                icon: const Icon(CupertinoIcons.trash),
                onPressed:
                    object(value)['id'] == widget.repository.profile.apiKeyId
                    ? null
                    : () async {
                        if (!await confirm(
                          context,
                          'Revoke API Key',
                          'Connections using this key will stop working.',
                        )) {
                          return;
                        }
                        try {
                          await widget.repository.api.request(
                            '/api/v2/users/me/api-keys/${Uri.encodeComponent(object(value)['id'])}',
                            method: 'DELETE',
                          );
                          if (mounted) setState(() => _revision++);
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
              ),
            ),
        ],
      ),
    ),
  );
}
