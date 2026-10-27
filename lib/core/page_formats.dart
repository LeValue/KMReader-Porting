/// Flutter's portable raster codecs. AVIF/HEIF/TIFF/JPEG2000 support varies by
/// OS, so those formats use Komga's lossless PNG conversion instead.
bool portablePageMediaType(String type) => const {
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
  'image/bmp',
  'image/x-ms-bmp',
  'image/vnd.wap.wbmp',
}.contains(type.split(';').first.trim().toLowerCase());

bool portablePageBytes(List<int> bytes) {
  bool prefix(List<int> signature) =>
      bytes.length >= signature.length &&
      List.generate(
        signature.length,
        (i) => bytes[i] == signature[i],
      ).every((v) => v);
  if (prefix([0x89, 0x50, 0x4e, 0x47]) ||
      prefix([0xff, 0xd8]) ||
      prefix([0x47, 0x49, 0x46, 0x38]) ||
      prefix([0x42, 0x4d])) {
    return true;
  }
  if (bytes.length >= 12 &&
      prefix([0x52, 0x49, 0x46, 0x46]) &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true;
  }
  if (bytes.length < 4 || bytes[0] != 0 || bytes[1] != 0) return false;
  var offset = 2;
  for (var dimension = 0; dimension < 2; dimension++) {
    var size = 0, groups = 0;
    while (true) {
      if (offset >= bytes.length || groups++ >= 5) return false;
      final value = bytes[offset++];
      size = (size << 7) | (value & 0x7f);
      if (value & 0x80 == 0) break;
    }
    if (size == 0) return false;
  }
  return true;
}
