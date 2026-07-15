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

  test('a local tombstone wins over a stale fallback token', () async {
    SharedPreferences.setMockInitialValues({
      'auth_token_signed_out_v2': true,
      'auth_token_fallback_v1': 'stale-token',
    });

    final prefs = await SharedPreferences.getInstance();
    final snapshot = AppSecureStorage.readLocalSession(prefs);

    expect(snapshot.initialized, isTrue);
    expect(snapshot.token, isNull);
    expect(await AppSecureStorage.readToken(), isNull);
  });

  test('the atomic v2 record wins over stale legacy keys', () async {
    SharedPreferences.setMockInitialValues({
      'auth_session_v2': '{"state":"signed_out"}',
      'auth_token_store_initialized_v1': true,
      'auth_token_signed_out_v2': false,
      'auth_token_fallback_v1': 'stale-token',
    });

    final prefs = await SharedPreferences.getInstance();
    final snapshot = AppSecureStorage.readLocalSession(prefs);

    expect(snapshot.initialized, isTrue);
    expect(snapshot.token, isNull);
  });

  test(
    'a secure tombstone blocks legacy migration after prefs reset',
    () async {
      final original = FlutterSecureStoragePlatform.instance;
      addTearDown(() => FlutterSecureStoragePlatform.instance = original);
      FlutterSecureStoragePlatform.instance = _MemorySecureStorage({
        'token': 'legacy-token',
        'auth_session_state_v2': 'signed_out',
      });
      SharedPreferences.setMockInitialValues({});

      expect(await AppSecureStorage.readToken(), isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('auth_token_store_initialized_v1'), isTrue);
      expect(prefs.getBool('auth_token_signed_out_v2'), isTrue);
      expect(prefs.getString('auth_token_fallback_v1'), isNull);
    },
  );

  test('a stale same-token write cannot clear a newer session', () async {
    SharedPreferences.setMockInitialValues({});

    final first = await AppSecureStorage.saveToken('same-token');
    final second = await AppSecureStorage.saveToken('same-token');

    await AppSecureStorage.clearTokenIfOwned(first);
    expect(await AppSecureStorage.readToken(), 'same-token');

    await AppSecureStorage.clearTokenIfOwned(second);
    expect(await AppSecureStorage.readToken(), isNull);
  });

  test('concurrent local writes commit in request order', () async {
    SharedPreferences.setMockInitialValues({});

    final first = AppSecureStorage.saveToken('older-token');
    final second = AppSecureStorage.saveToken('newer-token');

    await Future.wait([first, second]);
    expect(await AppSecureStorage.readToken(), 'newer-token');
  });

  test(
    'reads the cached session synchronously for the first app frame',
    () async {
      SharedPreferences.setMockInitialValues({
        'auth_token_store_initialized_v1': true,
        'auth_token_fallback_v1': ' cached-token ',
      });

      final prefs = await SharedPreferences.getInstance();
      final snapshot = AppSecureStorage.readLocalSession(prefs);

      expect(snapshot.initialized, isTrue);
      expect(snapshot.token, 'cached-token');
    },
  );
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
