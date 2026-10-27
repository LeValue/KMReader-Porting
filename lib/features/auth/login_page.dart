import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/models.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.app, this.profile});
  final AppController app;
  final ServerProfile? profile;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _address = TextEditingController(),
      _name = TextEditingController(),
      _username = TextEditingController(),
      _password = TextEditingController();
  Authentication _auth = Authentication.password;
  bool _busy = false, _obscure = true, _claim = false;
  bool _autoKey = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _autoKey = widget.app.store.setting<bool>('autoCreateApiKey') ?? true;
    final s = widget.profile;
    if (s != null) {
      _address.text = s.url;
      _name.text = s.name;
      _username.text = s.email;
      _auth = s.authentication;
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _name.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.login(
        address: _address.text,
        name: _name.text,
        authentication: _auth,
        username: _username.text,
        password: _password.text,
        claim: _claim,
        autoCreateApiKey: _autoKey,
      );
      widget.app.store.setSetting('autoCreateApiKey', _autoKey);
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'Add Server'))),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Icon(
              CupertinoIcons.tray_2,
              size: 52,
              color: Theme.of(context).colorScheme.secondary,
            ),
            const SizedBox(height: 24),
            Text(
              tr(context, 'Connect to Komga'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 24),
            AutofillGroup(
              child: Form(
                key: _form,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _address,
                      enabled: !_busy,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: tr(context, 'Server URL'),
                        hintText: 'https://komga.example.com',
                      ),
                      validator: (v) {
                        try {
                          normalizeServerUrl(v ?? '');
                          return null;
                        } catch (e) {
                          return e.toString();
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _name,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        labelText: tr(context, 'Name'),
                        hintText: tr(context, 'Optional'),
                      ),
                    ),
                    const SizedBox(height: 20),
                    SegmentedButton<Authentication>(
                      segments: [
                        ButtonSegment(
                          value: Authentication.password,
                          label: Text(tr(context, 'Password')),
                        ),
                        ButtonSegment(
                          value: Authentication.apiKey,
                          label: Text(tr(context, 'API Key')),
                        ),
                      ],
                      selected: {_auth},
                      onSelectionChanged: _busy
                          ? null
                          : (v) => setState(() {
                              _auth = v.first;
                              _claim = false;
                            }),
                    ),
                    const SizedBox(height: 20),
                    if (_auth == Authentication.password) ...[
                      TextFormField(
                        controller: _username,
                        enabled: !_busy,
                        autofillHints: const [AutofillHints.username],
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: tr(context, 'Email'),
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? tr(context, 'Required')
                            : null,
                      ),
                      const SizedBox(height: 14),
                    ],
                    TextFormField(
                      controller: _password,
                      enabled: !_busy,
                      obscureText: _obscure,
                      autocorrect: false,
                      autofillHints: _auth == Authentication.password
                          ? const [AutofillHints.password]
                          : null,
                      decoration: InputDecoration(
                        labelText: tr(
                          context,
                          _auth == Authentication.password
                              ? 'Password'
                              : 'API Key',
                        ),
                        suffixIcon: IconButton(
                          onPressed: () => setState(() => _obscure = !_obscure),
                          tooltip: tr(context, 'Show password'),
                          icon: Icon(
                            _obscure
                                ? CupertinoIcons.eye
                                : CupertinoIcons.eye_slash,
                          ),
                        ),
                      ),
                      validator: (v) => v == null || v.isEmpty
                          ? tr(context, 'Required')
                          : null,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    if (_auth == Authentication.password)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          tr(context, 'Create API Key Automatically'),
                        ),
                        subtitle: Text(
                          tr(
                            context,
                            'Use a device key instead of storing the password.',
                          ),
                        ),
                        value: _autoKey,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _autoKey = v),
                      ),
                    if (_auth == Authentication.password)
                      CheckboxListTile(
                        value: _claim,
                        contentPadding: EdgeInsets.zero,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _claim = v!),
                        title: Text(tr(context, 'Set up a new Komga server')),
                        subtitle: Text(
                          tr(context, 'Create the first administrator account'),
                        ),
                      ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _error!,
                          key: const Key('login-error'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(tr(context, 'Sign In')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              tr(
                context,
                'Your credentials are stored securely on this device.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Spacer(),
                Image.asset('assets/logo.png', height: 120),
                const SizedBox(height: 40),
                Text(
                  'KMReader',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 40),
                Text(
                  tr(context, 'Your Komga library, ready to read'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize: 20,
                    fontWeight: FontWeight.w400,
                    color: Theme.of(context).hintColor,
                  ),
                ),
                const Spacer(),
                if (app.startupError != null) Text(app.startupError!),
                if (app.servers.isNotEmpty)
                  ...app.servers.map(
                    (s) => ListTile(
                      leading: const Icon(CupertinoIcons.tray_2),
                      title: Text(s.name),
                      subtitle: Text(s.email),
                      onTap: () async {
                        try {
                          await app.activate(s);
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                    ),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => LoginPage(app: app),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(tr(context, 'Get Started')),
                        const SizedBox(width: 8),
                        const Icon(CupertinoIcons.arrow_right, size: 18),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
