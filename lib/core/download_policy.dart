import 'models.dart';
import 'store.dart';

class DownloadPolicy {
  const DownloadPolicy({
    this.background = true,
    this.unmetered = false,
    this.charging = false,
  });
  final bool background, unmetered, charging;
  factory DownloadPolicy.read(LocalStore store) {
    final value = object(store.setting<dynamic>('downloadPolicy'));
    return DownloadPolicy(
      background: value['background'] != false,
      unmetered: value['unmetered'] == true,
      charging: value['charging'] == true,
    );
  }
  Json toJson() => {
    'background': background,
    'unmetered': unmetered,
    'charging': charging,
  };
  bool permits(TransferConditions conditions) =>
      conditions.connected &&
      (!unmetered || !conditions.metered) &&
      (!charging || conditions.charging);
}

class TransferConditions {
  const TransferConditions({
    this.connected = true,
    this.metered = false,
    this.charging = true,
  });
  final bool connected, metered, charging;
  factory TransferConditions.parse(Json value) => TransferConditions(
    connected: value['connected'] == true,
    metered: value['metered'] != false,
    charging: value['charging'] == true,
  );
}
