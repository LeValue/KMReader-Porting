import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/kindle/chrome.dart';
import '../../core/kindle/client.dart';
import '../../core/kindle/import.dart';
import '../../core/kindle/send_login.dart';
import '../../ui/strings.dart';

class KindleSendLoginPage extends StatefulWidget {
  const KindleSendLoginPage({super.key, required this.importer});
  final KindleImporter importer;
  @override
  State<KindleSendLoginPage> createState() => _KindleSendLoginPageState();
}

class _KindleSendLoginPageState extends State<KindleSendLoginPage> {
  final _attempt = KindleSendLoginAttempt();
  final _cancel = KindleImportCancellation();
  bool _busy = false, _authorized = false;
  String? _error;
  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      await openKindleChrome(_attempt.url);
    } catch (_) {
      if (mounted) {
        setState(() => _error = tr(context, 'Unable to open the browser.'));
      }
    }
  }

  Future<void> _redeem(Uri uri) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.importer.authorize(_attempt, uri, _cancel);
      _authorized = true;
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is KindleFailure
              ? '${tr(context, error.code == 'import_account_unconfirmed' ? 'Use the same Amazon account as this Kindle library. Account matching could not be confirmed.' : 'Amazon authorization failed. Retry with a new login.')}\n$error'
              : tr(
                  context,
                  'Amazon authorization failed. Retry with a new login.',
                ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _paste() async {
    final value = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !KindleSendLoginAttempt.isCallback(uri)) {
      if (mounted) {
        setState(
          () => _error = tr(
            context,
            'Copy the complete Amazon return address from your browser.',
          ),
        );
      }
      return;
    }
    await _redeem(uri);
    if (_authorized &&
        (await Clipboard.getData(Clipboard.kTextPlain))?.text == value) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'Authorize Send to Kindle'))),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            tr(
              context,
              'Sign in with the same Amazon account. This authorizes sending documents and keeps your reading connection.',
            ),
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(20),
            child: SelectableText(_error!),
          ),
        if (Platform.isAndroid)
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri(_attempt.url.toString()),
              ),
              initialSettings: InAppWebViewSettings(
                incognito: true,
                javaScriptEnabled: true,
                useShouldOverrideUrlLoading: true,
                supportMultipleWindows: false,
                thirdPartyCookiesEnabled: true,
              ),
              shouldOverrideUrlLoading: (_, action) async {
                final uri = Uri.tryParse(action.request.url?.toString() ?? '');
                if (action.isForMainFrame &&
                    uri != null &&
                    KindleSendLoginAttempt.isCallback(uri)) {
                  unawaited(_redeem(uri));
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
              },
              onLoadStart: (_, url) {
                final uri = Uri.tryParse(url?.toString() ?? '');
                if (uri != null && KindleSendLoginAttempt.isCallback(uri)) {
                  unawaited(_redeem(uri));
                }
              },
            ),
          )
        else ...[
          FilledButton.icon(
            onPressed: _busy ? null : _open,
            icon: const Icon(Icons.open_in_browser),
            label: Text(tr(context, 'Open Amazon sign-in')),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              tr(
                context,
                'After signing in, copy the complete return address and paste it here.',
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _paste,
            icon: const Icon(Icons.content_paste),
            label: Text(tr(context, 'Complete with copied address')),
          ),
        ],
      ],
    ),
  );
}
