// lib/core/storage/secure_storage.dart
import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSecureStorage {
  static const _keyToken = 'token';
  static const _fallbackKeyToken = 'auth_token_fallback_v1';
  static const _initializedKey = 'auth_token_store_initialized_v1';
  static const _secureOperationTimeout = Duration(seconds: 2);

  // Keep the default options so tokens written by v1.0.26 remain readable.
  static const _storage = FlutterSecureStorage();
  static int _writeGeneration = 0;

  static Future<void> saveToken(String? token) async {
    if (token == null) {
      await clearToken();
      return;
    }

    final normalized = token.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(token, 'token', 'Token must not be empty');
    }

    final generation = ++_writeGeneration;
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(_fallbackKeyToken, normalized);
    await prefs.setBool(_initializedKey, true);
    if (!saved) {
      throw StateError('Unable to persist the authentication token');
    }

    // The durable local copy is already committed. A vendor keystore or a
    // re-signed iOS keychain must never block the login transition.
    unawaited(_mirrorToSecureStorage(normalized, generation));
  }

  static Future<String?> readToken() async {
    final prefs = await SharedPreferences.getInstance();
    final fallback = _normalized(prefs.getString(_fallbackKeyToken));
    if (fallback != null) return fallback;

    // Once this store has been initialized, an absent local token means the
    // user explicitly signed out. Do not resurrect a late secure-store write.
    if (prefs.getBool(_initializedKey) == true) return null;

    String? legacyToken;
    try {
      legacyToken = _normalized(
        await _storage.read(key: _keyToken).timeout(_secureOperationTimeout),
      );
    } catch (error, stackTrace) {
      _logSecureStorageFailure('legacy_read', error, stackTrace);
    }

    await prefs.setBool(_initializedKey, true);
    if (legacyToken == null) return null;

    final migrated = await prefs.setString(_fallbackKeyToken, legacyToken);
    if (!migrated) {
      throw StateError('Unable to migrate the authentication token');
    }
    return legacyToken;
  }

  static Future<void> clearToken() async {
    ++_writeGeneration;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_fallbackKeyToken);
    await prefs.setBool(_initializedKey, true);
    unawaited(_deleteSecureToken());
  }

  static Future<void> clearTokenIfMatches(String token) async {
    if (await readToken() == token) await clearToken();
  }

  static Future<void> _mirrorToSecureStorage(
    String token,
    int generation,
  ) async {
    try {
      await _storage
          .write(key: _keyToken, value: token)
          .timeout(_secureOperationTimeout);
    } catch (error, stackTrace) {
      _logSecureStorageFailure('mirror_write', error, stackTrace);
    } finally {
      if (generation != _writeGeneration) {
        await _deleteSecureToken();
      }
    }
  }

  static Future<void> _deleteSecureToken() async {
    try {
      await _storage.delete(key: _keyToken).timeout(_secureOperationTimeout);
    } catch (error, stackTrace) {
      _logSecureStorageFailure('delete', error, stackTrace);
    }
  }

  static String? _normalized(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    if (normalized == 'Data has been reset') return null;
    return normalized;
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
}
