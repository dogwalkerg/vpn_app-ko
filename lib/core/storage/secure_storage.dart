// lib/core/storage/secure_storage.dart
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalAuthSessionSnapshot {
  const LocalAuthSessionSnapshot({
    required this.initialized,
    required this.token,
  });

  final bool initialized;
  final String? token;
}

class AuthTokenWriteReceipt {
  const AuthTokenWriteReceipt(this.revision);

  final int revision;
}

class AppSecureStorage {
  static const _keyToken = 'token';
  static const _keySecureSessionState = 'auth_session_state_v2';
  static const _secureSignedOutValue = 'signed_out';
  static const _localSessionKey = 'auth_session_v2';
  static const _localSignedInValue = 'signed_in';
  static const _localSignedOutValue = 'signed_out';
  static const _fallbackKeyToken = 'auth_token_fallback_v1';
  static const _initializedKey = 'auth_token_store_initialized_v1';
  static const _signedOutKey = 'auth_token_signed_out_v2';
  static const _secureOperationTimeout = Duration(seconds: 2);

  // Keep the default options so tokens written by v1.0.26 remain readable.
  static const _storage = FlutterSecureStorage();
  static int _writeGeneration = 0;
  static Future<void>? _localMutationTail;

  static Future<AuthTokenWriteReceipt> saveToken(String token) {
    final normalized = token.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(token, 'token', 'Token must not be empty');
    }

    final generation = ++_writeGeneration;
    return _serializeLocalMutation(() async {
      final prefs = await SharedPreferences.getInstance();
      final committed = await prefs.setString(
        _localSessionKey,
        jsonEncode({'state': _localSignedInValue, 'token': normalized}),
      );
      if (!committed) {
        throw StateError('Unable to persist the authentication token');
      }

      // Keep the v1 fallback best-effort for downgrade compatibility. The
      // single v2 record above is the only authoritative session state.
      try {
        await prefs.setString(_fallbackKeyToken, normalized);
        await prefs.setBool(_signedOutKey, false);
        await prefs.setBool(_initializedKey, true);
      } catch (error, stackTrace) {
        _logLocalCompatibilityFailure('signed_in', error, stackTrace);
      }
      return AuthTokenWriteReceipt(generation);
    });
  }

  static Future<String?> readToken() async {
    final pendingMutation = _localMutationTail;
    if (pendingMutation != null) await pendingMutation;
    final prefs = await SharedPreferences.getInstance();
    final snapshot = readLocalSession(prefs);
    if (snapshot.token != null) return snapshot.token;

    // Once this store has been initialized, an absent local token means the
    // user explicitly signed out. Do not resurrect a late secure-store write.
    if (snapshot.initialized) return null;

    String? secureSessionState;
    String? legacyToken;
    try {
      secureSessionState = _normalized(
        await _storage
            .read(key: _keySecureSessionState)
            .timeout(_secureOperationTimeout),
      );
      if (secureSessionState == _secureSignedOutValue) {
        await _persistLocalSignedOut(prefs);
        return null;
      }
      legacyToken = _normalized(
        await _storage.read(key: _keyToken).timeout(_secureOperationTimeout),
      );
    } catch (error, stackTrace) {
      _logSecureStorageFailure('legacy_read', error, stackTrace);
    }
    if (legacyToken == null) {
      await _persistLocalSignedOut(prefs);
      return null;
    }

    await saveToken(legacyToken);
    return legacyToken;
  }

  static LocalAuthSessionSnapshot readLocalSession(SharedPreferences prefs) {
    final record = prefs.getString(_localSessionKey);
    if (record != null) return _decodeLocalSession(record);

    final signedOut = prefs.getBool(_signedOutKey) == true;
    return LocalAuthSessionSnapshot(
      initialized: signedOut || prefs.getBool(_initializedKey) == true,
      token: signedOut ? null : _normalized(prefs.getString(_fallbackKeyToken)),
    );
  }

  static Future<void> clearToken({bool requireSecureCleanup = false}) {
    ++_writeGeneration;
    return _serializeLocalMutation(() async {
      final prefs = await SharedPreferences.getInstance();
      await _persistLocalSignedOut(prefs);
      try {
        final removed = await prefs.remove(_fallbackKeyToken);
        if (!removed && prefs.containsKey(_fallbackKeyToken)) {
          developer.log(
            'secure_storage_local_token_remove failed; tombstone retained',
            name: 'vpn_app.auth',
          );
        }
      } catch (error, stackTrace) {
        _logLocalCompatibilityFailure('remove_fallback', error, stackTrace);
      }
      await _clearLegacySecureSession(required: requireSecureCleanup);
    });
  }

  static Future<void> clearTokenIfOwned(AuthTokenWriteReceipt receipt) async {
    if (_writeGeneration != receipt.revision) return;
    await clearToken();
  }

  static Future<T> _serializeLocalMutation<T>(Future<T> Function() operation) {
    final previous = _localMutationTail;
    final result = previous == null
        ? Future<T>.sync(operation)
        : previous.then<T>((_) => operation());
    late final Future<void> tail;
    tail = result
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() {
          if (identical(_localMutationTail, tail)) _localMutationTail = null;
        });
    _localMutationTail = tail;
    return result;
  }

  static Future<void> _persistLocalSignedOut(SharedPreferences prefs) async {
    final committed = await prefs.setString(
      _localSessionKey,
      jsonEncode({'state': _localSignedOutValue}),
    );
    if (!committed) {
      throw StateError('Unable to persist the signed-out session marker');
    }

    try {
      await prefs.setBool(_signedOutKey, true);
      await prefs.setBool(_initializedKey, true);
    } catch (error, stackTrace) {
      _logLocalCompatibilityFailure('signed_out', error, stackTrace);
    }
  }

  static Future<void> _clearLegacySecureSession({
    required bool required,
  }) async {
    final outcomes = await Future.wait([
      _trySecureOperation(
        'signed_out_marker',
        () => _storage.write(
          key: _keySecureSessionState,
          value: _secureSignedOutValue,
        ),
      ),
      _trySecureOperation(
        'legacy_delete',
        () => _storage.delete(key: _keyToken),
      ),
    ]);
    if (required && !outcomes.any((succeeded) => succeeded)) {
      throw StateError('Unable to revoke the persisted secure session');
    }
  }

  static Future<bool> _trySecureOperation(
    String operation,
    Future<void> Function() callback,
  ) async {
    try {
      await callback().timeout(_secureOperationTimeout);
      return true;
    } catch (error, stackTrace) {
      _logSecureStorageFailure(operation, error, stackTrace);
      return false;
    }
  }

  static String? _normalized(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    if (normalized == 'Data has been reset') return null;
    return normalized;
  }

  static LocalAuthSessionSnapshot _decodeLocalSession(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['state'] == _localSignedInValue) {
        final token = _normalized(decoded['token']?.toString());
        if (token != null) {
          return LocalAuthSessionSnapshot(initialized: true, token: token);
        }
      }
      if (decoded is Map && decoded['state'] == _localSignedOutValue) {
        return const LocalAuthSessionSnapshot(initialized: true, token: null);
      }
    } catch (_) {}

    // A present but corrupt authoritative record must not resurrect an older
    // fallback or Keychain token.
    return const LocalAuthSessionSnapshot(initialized: true, token: null);
  }

  static void _logSecureStorageFailure(
    String operation,
    Object error,
    StackTrace stackTrace,
  ) {
    developer.log(
      'secure_storage_$operation failed; using the durable local session',
      name: 'vpn_app.auth',
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void _logLocalCompatibilityFailure(
    String operation,
    Object error,
    StackTrace stackTrace,
  ) {
    developer.log(
      'local_session_compatibility_$operation failed; v2 record retained',
      name: 'vpn_app.auth',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
