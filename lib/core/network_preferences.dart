import 'store.dart';

class NetworkPreferences {
  const NetworkPreferences({
    this.request = 15,
    this.download = 60,
    this.authentication = 5,
    this.retries = 0,
  });
  final int request, download, authentication, retries;
  factory NetworkPreferences.fromStore(LocalStore store) {
    int number(String key, int fallback, int min, int max) {
      final value = store.setting<dynamic>(key);
      return value is num && value.isFinite
          ? value.round().clamp(min, max)
          : fallback;
    }

    return NetworkPreferences(
      request: number('requestTimeout', 15, 1, 600),
      download: number('downloadTimeout', 60, 1, 3600),
      authentication: number('authTimeout', 5, 1, 600),
      retries: number('apiRetryCount', 0, 0, 5),
    );
  }
}
