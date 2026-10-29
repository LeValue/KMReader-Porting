import 'dart:convert';
import 'dart:async';

class ServerEvent {
  const ServerEvent(this.type, this.data, this.id);
  final String type, data;
  final String? id;
  Map<String, dynamic>? get object {
    try {
      final value = jsonDecode(data);
      return value is Map ? Map<String, dynamic>.from(value) : null;
    } on FormatException {
      return null;
    }
  }
}

/// Dispatches complete SSE messages, preserving UTF-8, multiline payloads and
/// event IDs. Heartbeat comments and truncated messages do not become updates.
Stream<ServerEvent> decodeServerEvents(Stream<List<int>> bytes) {
  var type = 'message', first = true, length = 0, invalid = false;
  String? id;
  final data = <String>[];
  return bytes
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .transform(
        StreamTransformer<String, ServerEvent>.fromHandlers(
          handleData: (line, sink) {
            if (first) {
              line = line.replaceFirst(RegExp('^\uFEFF'), '');
              first = false;
            }
            if (line.isEmpty) {
              if (!invalid && data.isNotEmpty) {
                sink.add(ServerEvent(type, data.join('\n'), id));
              }
              type = 'message';
              data.clear();
              length = 0;
              invalid = false;
              return;
            }
            if (invalid || line.startsWith(':')) return;
            final colon = line.indexOf(':');
            final field = colon < 0 ? line : line.substring(0, colon);
            var value = colon < 0 ? '' : line.substring(colon + 1);
            if (value.startsWith(' ')) value = value.substring(1);
            switch (field) {
              case 'event':
                type = value;
              case 'id':
                if (!value.contains('\u0000')) id = value;
              case 'data':
                length += value.length + 1;
                if (length > 1024 * 1024) {
                  invalid = true;
                  data.clear();
                  sink.addError(
                    const FormatException(
                      'Server event exceeds the size limit.',
                    ),
                  );
                } else {
                  data.add(value);
                }
            }
          },
        ),
      );
}
