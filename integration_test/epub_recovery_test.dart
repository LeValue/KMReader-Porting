import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/epub_recovery_check.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  verifyNativeEpubRecovery();
}
