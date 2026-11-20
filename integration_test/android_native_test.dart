import 'reader_display_test.dart' as display;
import 'epub_reader_test.dart' as reader;
import 'support/android_epub_comparison.dart';

void main() {
  reader.main();
  verifyAndroidEpubComparison();
  // The installer opens another Android activity after the reader checks.
  display.main();
}
