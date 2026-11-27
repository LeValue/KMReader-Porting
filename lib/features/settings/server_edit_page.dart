import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/models.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';

class ServerEditPage extends StatefulWidget {
  const ServerEditPage({super.key, required this.app, required this.profile});

  final AppController app;
  final ServerProfile profile;

  @override
  State<ServerEditPage> createState() => _ServerEditPageState();
}

class _ServerEditPageState extends State<ServerEditPage> {
  late final _name = TextEditingController(text: widget.profile.name);
  late final _address = TextEditingController(text: widget.profile.url);
  final _secret = TextEditingController();
  late var _method = widget.profile.authentication;
  late var _protected = widget.profile.isProtected;
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.app.updateServer(
        widget.profile,
        name: _name.text,
        isProtected: _protected,
        address: _address.text,
        authenticationReason: tr(context, 'Authenticate to edit this server.'),
        authentication: _method,
        secret: _secret.text,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (failure) {
      if (mounted) setState(() => _error = tr(context, failure.toString()));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'Edit Server'))),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            TextField(
              controller: _name,
              enabled: !_saving,
              decoration: InputDecoration(labelText: tr(context, 'Name')),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _address,
              enabled: !_saving,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: tr(context, 'Server Address'),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Text(widget.profile.email),
            const SizedBox(height: 12),
            DropdownButtonFormField<Authentication>(
              initialValue: _method,
              decoration: InputDecoration(
                labelText: tr(context, 'Authentication Method'),
              ),
              items: [
                DropdownMenuItem(
                  value: Authentication.password,
                  child: Text(tr(context, 'Password')),
                ),
                DropdownMenuItem(
                  value: Authentication.apiKey,
                  child: Text(tr(context, 'API Key')),
                ),
              ],
              onChanged: _saving
                  ? null
                  : (method) {
                      if (method == null || method == _method) return;
                      setState(() {
                        _method = method;
                        _secret.clear();
                      });
                    },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _secret,
              enabled: !_saving,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: tr(
                  context,
                  _method == Authentication.apiKey
                      ? 'New API Key'
                      : 'New Password',
                ),
                helperText: _address.text.trim() != widget.profile.url
                    ? tr(
                        context,
                        'Enter credentials for the new server address.',
                      )
                    : _method == widget.profile.authentication
                    ? tr(context, 'Leave blank to keep the saved credentials.')
                    : null,
                helperMaxLines: 2,
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _protected,
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _protected = value),
              title: Text(tr(context, 'Protected Server')),
              subtitle: Text(
                tr(
                  context,
                  'Require device authentication to open this server.',
                ),
              ),
            ),
            if (_error case final message?)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  message,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(tr(context, 'Save')),
            ),
            if (_saving) const LinearProgressIndicator(),
          ],
        ),
      ),
    ),
  );
}

class ProtectedServersButton extends StatelessWidget {
  const ProtectedServersButton({super.key, required this.app});

  final AppController app;

  Future<void> _open(BuildContext context) async {
    try {
      await app.chooseProtectedServer(
        tr(context, 'Authenticate to view protected servers.'),
        (profiles) async {
          if (!context.mounted) return null;
          return showDialog<ServerProfile>(
            context: context,
            builder: (context) => SimpleDialog(
              title: Text(tr(context, 'Protected Servers')),
              children: [
                for (final profile in profiles)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, profile),
                    child: Text(profile.name),
                  ),
              ],
            ),
          );
        },
      );
    } catch (failure) {
      if (context.mounted) showError(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.lock_outline),
    title: Text(tr(context, 'Protected Servers')),
    onTap: () => _open(context),
  );
}
