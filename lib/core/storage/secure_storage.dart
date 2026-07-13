// lib/core/storage/secure_storage.dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSecureStorage {
  static const _keyToken = 'token';
  static const _fallbackKeyToken = 'auth_token_fallback_v1';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: true),
  );

  static Future<void> saveToken(String? token) async {
    if (token == null) {
      await clearToken();
      return;
    }

    try {
      await _storage.write(key: _keyToken, value: token);
      if (await _storage.read(key: _keyToken) == token) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_fallbackKeyToken);
        return;
      }
    } catch (_) {
      // Some vendor keystores and re-signed iOS builds cannot initialize the
      // secure-storage backend. Keep a local fallback so login still persists.
    }

    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_fallbackKeyToken, token)) {
      throw StateError('Unable to persist the authentication token');
    }
  }

  static Future<String?> readToken() async {
    try {
      final token = await _storage.read(key: _keyToken);
      if (token != null && token.trim().isNotEmpty) return token;
    } catch (_) {
      // Fall through to the cross-platform preferences fallback.
    }

    final prefs = await SharedPreferences.getInstance();
    final fallback = prefs.getString(_fallbackKeyToken);
    return fallback == null || fallback.trim().isEmpty ? null : fallback;
  }

  static Future<void> clearToken() async {
    try {
      await _storage.delete(key: _keyToken);
    } catch (_) {
      // Local logout must still complete if the platform keystore is broken.
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_fallbackKeyToken);
  }

  static Future<void> clearTokenIfMatches(String token) async {
    if (await readToken() == token) await clearToken();
  }
}
