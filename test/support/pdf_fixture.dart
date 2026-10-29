import 'dart:convert';
import 'dart:typed_data';

/// Two standard PDF pages with different aspect ratios and solid artwork.
Uint8List rasterPdfFixture() {
  const red = '1 0 0 rg 0 0 300 450 re f\n';
  const blue = '0 0 1 rg 0 0 450 300 re f\n';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 450] /Resources << >> /Contents 5 0 R >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 450 300] /Resources << >> /Contents 6 0 R >>',
    '<< /Length ${red.length} >>\nstream\n${red}endstream',
    '<< /Length ${blue.length} >>\nstream\n${blue}endstream',
  ];
  final output = StringBuffer('%PDF-1.4\n'), offsets = <int>[];
  for (final (index, object) in objects.indexed) {
    offsets.add(output.length);
    output.write('${index + 1} 0 obj\n$object\nendobj\n');
  }
  final xref = output.length;
  output.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    output.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(ascii.encode(output.toString()));
}
