import 'package:flutter/foundation.dart';

class ClientLogEntry {
  ClientLogEntry(this.level, this.category, this.message)
    : time = DateTime.now().toUtc();
  final String level, category, message;
  final DateTime time;
  @override
  String toString() => '${time.toIso8601String()} [$level] $category: $message';
}

/// Bounded diagnostics never receive credentials, URLs, payloads or book text.
class ClientLog extends ChangeNotifier {
  static final instance = ClientLog();
  final _entries = <ClientLogEntry>[];
  List<ClientLogEntry> get entries => List.unmodifiable(_entries);
  void add(String level, String category, String message) {
    _entries.add(ClientLogEntry(level, category, message));
    if (_entries.length > 500) _entries.removeRange(0, _entries.length - 500);
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  String get exported => _entries.join('\n');
}
