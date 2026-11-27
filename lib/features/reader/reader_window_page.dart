import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/app_controller.dart';
import '../../core/local_library.dart';
import '../../core/models.dart';
import '../../core/reader_launch.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'document_readers.dart';
import 'reader_page.dart';

class ReaderWindowPage extends StatefulWidget {
  const ReaderWindowPage({super.key, required this.app, required this.launch});
  final AppController app;
  final ReaderLaunch launch;

  @override
  State<ReaderWindowPage> createState() => _ReaderWindowPageState();
}

class _ReaderWindowPageState extends State<ReaderWindowPage> {
  Object? _error;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    widget.app.deviceLock.addListener(_onUnlock);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onUnlock());
  }

  void _onUnlock() {
    if (_error == null && !widget.app.deviceLock.locked) _load();
  }

  @override
  void dispose() {
    widget.app.deviceLock.removeListener(_onUnlock);
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted || _opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final app = widget.app;
      final launch = widget.launch;
      final local = launch.profile == LocalLibrary.scope;
      final profile = app.servers
          .where((item) => item.id == launch.profile)
          .firstOrNull;
      if (!local && profile == null) {
        throw const ApiFailure('This server is no longer saved.');
      }
      if (launch.indexed &&
          (local ||
              profile?.isProtected == true ||
              app.deviceLock.enabled ||
              app.store.setting<bool>('privacyProtection') == true ||
              app.store.setting<bool>('systemLibraryIndex') != true)) {
        throw const ApiFailure('This indexed download is no longer available.');
      }
      if (!local && app.repository?.profile.id != launch.profile) {
        await app.activate(
          profile!,
          authenticationReason: tr(
            context,
            'Authenticate to open this server.',
          ),
        );
      }
      if (!mounted) return;
      final repository = local ? app.localLibrary : app.repository!;
      final copy = repository.store.download(launch.profile, launch.book);
      if (launch.indexed && copy?['status'] != 'ready') {
        throw const ApiFailure('This indexed download is no longer available.');
      }
      final book = !local && copy?['status'] == 'ready'
          ? repository.overlay(Book(object(copy!['book'])))
          : await repository.book(launch.book);
      final original = repository.bookFile(book);
      if ((local || launch.indexed) && !await original.exists()) {
        throw const ApiFailure('The downloaded file is missing.');
      }
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => local && book.format != 'comic'
              ? DocumentReader(
                  repository: repository,
                  book: book,
                  load: () async => original,
                  incognito: false,
                )
              : ReaderPage(
                  repository: repository,
                  book: book,
                  rasterPages: local ? LocalComicPages(original) : null,
                ),
        ),
      );
      if (mounted) {
        if (Platform.isWindows) exit(0);
        await SystemNavigator.pop();
      }
    } catch (failure) {
      if (mounted) setState(() => _error = failure);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'Reader'))),
    body: _error == null
        ? const Center(child: CircularProgressIndicator.adaptive())
        : FailureView(error: _error!, retry: _load),
  );
}
