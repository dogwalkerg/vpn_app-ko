import 'dart:async';

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

  test('a hanging secure write never blocks login persistence', () async {
    final original = FlutterSecureStoragePlatform.instance;
    addTearDown(() => FlutterSecureStoragePlatform.instance = original);
    FlutterSecureStoragePlatform.instance = _HangingSecureStorage();
    SharedPreferences.setMockInitialValues({});

    final stopwatch = Stopwatch()..start();
    await AppSecureStorage.saveToken(
      'durable-token',
    ).timeout(const Duration(milliseconds: 500));
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(await AppSecureStorage.readToken(), 'durable-token');
  });

  test('migrates a token written by v1.0.26 default options', () async {
    final original = FlutterSecureStoragePlatform.instance;
    addTearDown(() => FlutterSecureStoragePlatform.instance = original);
    final storage = _MemorySecureStorage({'token': 'legacy-token'});
    FlutterSecureStoragePlatform.instance = storage;
    SharedPreferences.setMockInitialValues({});

    expect(await AppSecureStorage.readToken(), 'legacy-token');

    storage.values.clear();
    expect(await AppSecureStorage.readToken(), 'legacy-token');
  });

  test('an explicit signed-out marker prevents token resurrection', () async {
    final original = FlutterSecureStoragePlatform.instance;
    addTearDown(() => FlutterSecureStoragePlatform.instance = original);
    FlutterSecureStoragePlatform.instance = _MemorySecureStorage({
      'token': 'late-secure-token',
    });
    SharedPreferences.setMockInitialValues({
      'auth_token_store_initialized_v1': true,
    });

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

class _HangingSecureStorage extends FlutterSecureStoragePlatform {
  final Completer<void> _never = Completer<void>();

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => false;

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) => _never.future;

  @override
  Future<void> deleteAll({required Map<String, String> options}) =>
      _never.future;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => null;

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => const {};

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) => _never.future;
}

class _MemorySecureStorage extends FlutterSecureStoragePlatform {
  _MemorySecureStorage(Map<String, String> initialValues)
    : values = Map<String, String>.from(initialValues);

  final Map<String, String> values;

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => values.containsKey(key);

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    values.remove(key);
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    values.clear();
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => values[key];

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => Map<String, String>.from(values);

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    values[key] = value;
  }
}
