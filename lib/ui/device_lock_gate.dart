import 'dart:async';

import 'package:flutter/material.dart';

import '../core/device_lock.dart';
import 'strings.dart';

class DeviceLockGate extends StatefulWidget {
  const DeviceLockGate({super.key, required this.lock, required this.child});
  final DeviceLock lock;
  final Widget child;
  @override
  State<DeviceLockGate> createState() => _DeviceLockGateState();
}

class _DeviceLockGateState extends State<DeviceLockGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  void _unlock() {
    if (mounted && widget.lock.locked) {
      unawaited(widget.lock.unlock(tr(context, 'Unlock KMReader')));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      widget.lock.lock();
    } else if (state == AppLifecycleState.resumed) {
      _unlock();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.lock,
    builder: (context, _) {
      final lock = widget.lock;
      return Stack(
        fit: StackFit.expand,
        children: [
          Offstage(
            offstage: lock.locked,
            child: TickerMode(enabled: !lock.locked, child: widget.child),
          ),
          if (lock.locked)
            PopScope(
              canPop: false,
              child: Material(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: SafeArea(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.lock_outline, size: 56),
                            const SizedBox(height: 24),
                            Text(
                              tr(context, 'KMReader is locked'),
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            if (lock.error != null)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                child: Text(lock.error!),
                              ),
                            const SizedBox(height: 24),
                            FilledButton.icon(
                              onPressed: lock.busy ? null : _unlock,
                              icon: const Icon(Icons.fingerprint),
                              label: Text(tr(context, 'Unlock')),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
