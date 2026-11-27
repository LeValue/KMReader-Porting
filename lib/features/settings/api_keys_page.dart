import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../catalog/list_actions.dart';
import '../../ui/wheel_scroll.dart';

class ApiKeysPage extends StatefulWidget {
  const ApiKeysPage({super.key, required this.repository});
  final Repository repository;
  @override
  State<ApiKeysPage> createState() => _ApiKeysPageState();
}

class _ApiKeysPageState extends State<ApiKeysPage> {
  int _revision = 0;
  bool _busy = false;
  bool get _keyUnknown =>
      widget.repository.profile.authentication == Authentication.apiKey &&
      widget.repository.profile.apiKeyId == null;

  Future<void> _revoke(String id) async {
    if (_busy || _keyUnknown || id == widget.repository.profile.apiKeyId) {
      return;
    }
    if (!await confirm(
      context,
      'Revoke API Key',
      'Connections using this key will stop working.',
    )) {
      return;
    }
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.repository.api.request(
        '/api/v2/users/me/api-keys/${Uri.encodeComponent(id)}',
        method: 'DELETE',
      );
      if (mounted) setState(() => _revision++);
    } catch (failure) {
      if (mounted) showError(context, failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final comment = await askName(context, 'Create API Key');
    if (comment == null || !mounted || _busy) return;
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
          if (_keyUnknown)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(
                tr(
                  context,
                  'The active API key cannot be identified. Sign in with a password or a key created by KMReader to revoke keys here.',
                ),
              ),
            ),
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
                    _busy ||
                        _keyUnknown ||
                        text(object(value)['id']).isEmpty ||
                        object(value)['id'] ==
                            widget.repository.profile.apiKeyId
                    ? null
                    : () => _revoke(text(object(value)['id'])),
              ),
            ),
        ],
      ).withWheelScrolling(),
    ),
  );
}
