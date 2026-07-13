import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpn_app/core/storage/secure_storage.dart';

void main() {
  test('falls back when the platform secure store is unavailable', () async {
    final original = FlutterSecureStoragePlatform.instance;
    addTearDown(() => FlutterSecureStoragePlatform.instance = original);
    FlutterSecureStoragePlatform.instance = _UnavailableSecureStorage();
    SharedPreferences.setMockInitialValues({});

    await AppSecureStorage.saveToken('fallback-token');

    expect(await AppSecureStorage.readToken(), 'fallback-token');
    await AppSecureStorage.clearToken();
    expect(await AppSecureStorage.readToken(), isNull);
  });
}

class _UnavailableSecureStorage extends FlutterSecureStoragePlatform {
  UnsupportedError _error() => UnsupportedError('secure storage unavailable');

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) => Future<bool>.error(_error());

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) => Future<void>.error(_error());

  @override
  Future<void> deleteAll({required Map<String, String> options}) =>
      Future<void>.error(_error());

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) => Future<String?>.error(_error());

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) =>
      Future<Map<String, String>>.error(_error());

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) => Future<void>.error(_error());
}
