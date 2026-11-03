import 'package:integration_test/integration_test.dart';

import 'support/epub_recovery_check.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  verifyNativeEpubRecovery();
}
