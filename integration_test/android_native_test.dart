import 'reader_display_test.dart' as display;
import 'epub_reader_test.dart' as reader;

void main() {
  reader.main();
  // The installer opens another Android activity after the reader checks.
  display.main();
}
