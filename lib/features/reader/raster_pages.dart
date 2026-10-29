import 'dart:typed_data';

import '../../core/models.dart';

/// Page bytes for a local document rendered through the comic reader.
abstract interface class RasterPages {
  List<Json> get dimensions;
  Future<Uint8List> page(int number, {bool refresh = false});
}
