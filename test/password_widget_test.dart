import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/app_controller.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/settings/password_page.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:sqlite3/sqlite3.dart';

class _App extends AppController {
  _App({required super.store, required super.directory})
    : super(vault: const SecureVault());
  final gate = Completer<void>();
  final submitted = <String>[];
  @override
  Future<void> changePassword(Repository target, String password) {
    submitted.add(password);
    return gate.future;
  }
}

void main() {
  setUpAll(Strings.initialize);
  for (final width in [320.0, 1280.0]) {
    testWidgets(
      'password confirmation and pending navigation work at $width px',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = Directory.systemTemp.createTempSync('password-form-');
        final store = LocalStore(sqlite3.openInMemory());
        final app = _App(store: store, directory: directory);
        final repository = Repository(
          profile: const ServerProfile(
            id: 's',
            name: 'Fixture',
            url: 'https://example.invalid',
            email: 'reader@example.invalid',
            authentication: Authentication.apiKey,
          ),
          api: KomgaApi(
            Uri.parse('https://example.invalid'),
            authentication: Authentication.apiKey,
            credential: '',
          ),
          store: store,
          directory: directory,
        );
        final result = ValueNotifier<bool?>(null);
        try {
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: ValueListenableBuilder<bool?>(
                    valueListenable: result,
                    builder: (context, changed, _) => changed == true
                        ? const Text('Password updated')
                        : FilledButton(
                            onPressed: () async =>
                                result.value = await Navigator.push<bool>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => PasswordPage(
                                      app: app,
                                      repository: repository,
                                    ),
                                  ),
                                ),
                            child: const Text('Open password form'),
                          ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open password form'));
          await tester.pumpAndSettle();
          final submit = find.text('Update Password');
          await tester.tap(submit);
          await tester.pumpAndSettle();
          expect(find.text('Enter a new password.'), findsOneWidget);
          expect(app.submitted, isEmpty);
          await tester.enterText(
            find.byType(TextFormField).first,
            'new secret',
          );
          await tester.enterText(find.byType(TextFormField).last, 'different');
          await tester.tap(submit);
          await tester.pumpAndSettle();
          expect(find.text('Passwords do not match'), findsOneWidget);
          expect(app.submitted, isEmpty);
          await tester.enterText(find.byType(TextFormField).last, 'new secret');
          await tester.tap(submit);
          await tester.pump();
          expect(app.submitted, ['new secret']);
          final pageContext = tester.element(find.byType(PasswordPage));
          await Navigator.of(pageContext).maybePop();
          await tester.pump();
          expect(find.byType(PasswordPage), findsOneWidget);
          expect(
            tester
                .widgetList<TextField>(find.byType(TextField))
                .every((field) => field.enabled == false && field.obscureText),
            true,
          );
          app.gate.complete();
          await tester.pumpAndSettle();
          expect(find.text('Password updated'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          if (!app.gate.isCompleted) app.gate.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(repository.stopDownloadWork);
          app.dispose();
          result.dispose();
          store.close();
          directory.deleteSync(recursive: true);
        }
      },
    );
  }
}
