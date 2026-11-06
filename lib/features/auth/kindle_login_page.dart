import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;

import '../../core/app_controller.dart';
import '../../core/kindle/client.dart';
import '../../core/kindle/conversion.dart';
import '../../ui/strings.dart';

class KindleLoginPage extends StatefulWidget {
  const KindleLoginPage({super.key, required this.app});
  final AppController app;
  @override
  State<KindleLoginPage> createState() => _KindleLoginPageState();
}

class _KindleLoginPageState extends State<KindleLoginPage> {
  final _abort = Completer<void>();
  final _client = KindleClient();
  KindleLoginAttempt? _attempt;
  bool _busy = true, _redeeming = false;
  Object? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    if (!_abort.isCompleted) _abort.complete();
    _client.close();
    super.dispose();
  }

  Future<void> _start() async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      if (Platform.isWindows) {
        final session = await NativeKindlePreparation.connectWindows(
          widget.app.directory,
          importExisting:
              widget.app.store.setting<bool>('kindlePrototypeImported') != true,
          abortTrigger: _abort.future,
        );
        if (!mounted) return;
        await _finish(session);
      } else if (Platform.isAndroid) {
        var serial = await widget.app.vault.read('kindle-installation');
        if (serial == null) {
          serial = List.generate(16, (_) => Random.secure().nextInt(256))
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join()
              .toUpperCase();
          await widget.app.vault.write('kindle-installation', serial);
        }
        if (mounted) {
          setState(() {
            _attempt = KindleLoginAttempt(serial: serial!);
            _busy = false;
          });
        }
      } else {
        throw const KindleFailure('platform_unsupported');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _busy = false;
          _redeeming = false;
        });
      }
    }
  }

  Future<void> _finish(KindleSession session) async {
    if (!mounted) return;
    await widget.app.connectKindle(session);
    widget.app.store.setSetting('kindlePrototypeImported', true);
    // Retain credentials only in the app vault. The external prototype's
    // independent session is never removed or modified by account removal.
    if (Platform.isWindows) {
      final transient = File(
        p.join(widget.app.directory.path, 'kindle-login', 'session.dpapi'),
      );
      if (await transient.exists()) await transient.delete();
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _callback(Uri uri) async {
    if (_redeeming) return;
    try {
      final authorization = _attempt!.callback(uri);
      if (authorization == null) return;
      _redeeming = true;
      if (mounted) setState(() => _busy = true);
      // Redeem while this browser context is still alive, before navigating
      // to Amazon's landing page or disposing its authentication cookies.
      final session = await _client.register(_attempt!, authorization);
      if (mounted) await _finish(session);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _busy = false;
          _redeeming = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'Connect Kindle'))),
    body: _error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(CupertinoIcons.exclamationmark_triangle, size: 36),
                  const SizedBox(height: 16),
                  Text(_error.toString(), textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _start,
                    child: Text(tr(context, 'Retry')),
                  ),
                ],
              ),
            ),
          )
        : Stack(
            children: [
              if (_attempt != null)
                InAppWebView(
                  initialUrlRequest: URLRequest(
                    url: WebUri(_attempt!.url.toString()),
                  ),
                  initialSettings: InAppWebViewSettings(
                    incognito: true,
                    javaScriptEnabled: true,
                    useShouldOverrideUrlLoading: true,
                    supportMultipleWindows: false,
                    thirdPartyCookiesEnabled: true,
                  ),
                  shouldOverrideUrlLoading: (controller, action) async {
                    final uri = Uri.tryParse(
                      action.request.url?.toString() ?? '',
                    );
                    if (action.isForMainFrame &&
                        uri != null &&
                        KindleLoginAttempt.isCallback(uri)) {
                      unawaited(_callback(uri));
                      return NavigationActionPolicy.CANCEL;
                    }
                    return NavigationActionPolicy.ALLOW;
                  },
                  onLoadStart: (controller, url) {
                    final uri = Uri.tryParse(url?.toString() ?? '');
                    if (uri != null && KindleLoginAttempt.isCallback(uri)) {
                      unawaited(_callback(uri));
                    }
                  },
                  onLoadStop: (controller, url) {
                    if (mounted && !_redeeming) setState(() => _busy = false);
                  },
                ),
              if (_busy || _attempt == null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator.adaptive(),
                        const SizedBox(height: 20),
                        Text(
                          tr(
                            context,
                            Platform.isWindows
                                ? 'Complete the Amazon sign-in in your browser.'
                                : 'Connecting to Amazon.it…',
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
  );
}
