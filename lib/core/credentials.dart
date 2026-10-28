import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class CredentialVault {
  Future<String?> read(String id);
  Future<void> write(String id, String value);
  Future<void> delete(String id);
}

class SecureVault implements CredentialVault {
  const SecureVault();
  static const storage = FlutterSecureStorage();
  @override
  Future<String?> read(String id) => storage.read(key: 'server:$id');
  @override
  Future<void> write(String id, String value) =>
      storage.write(key: 'server:$id', value: value);
  @override
  Future<void> delete(String id) => storage.delete(key: 'server:$id');
}
