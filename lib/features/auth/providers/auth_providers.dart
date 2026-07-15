// lib/features/auth/providers/auth_providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vpn_app/core/models/feature_state.dart';
import '../models/domain/user.dart';
import 'auth_controller.dart';

export 'auth_controller.dart';

enum AuthSessionPhase { restoring, signedIn, signedOut }

AuthSessionPhase initialAuthSessionPhase({
  required bool localStoreInitialized,
  required String? token,
}) {
  if (token != null && token.trim().isNotEmpty) {
    return AuthSessionPhase.signedIn;
  }
  return localStoreInitialized
      ? AuthSessionPhase.signedOut
      : AuthSessionPhase.restoring;
}

/// Tracks whether a persisted session is still being restored at startup.
///
/// This is intentionally separate from [AuthState]: loading user data must not
/// make the router treat a stored session as signed out.
final authSessionPhaseProvider = StateProvider<AuthSessionPhase>(
  (ref) => AuthSessionPhase.restoring,
  name: 'authSessionPhase',
);

// Токен авторизации (читает AuthInterceptor)
final tokenProvider = StateProvider<String?>((ref) => null, name: 'authToken');

/// Message carried across the auth redirect after a session is invalidated.
final sessionNoticeProvider = StateProvider<String?>(
  (ref) => null,
  name: 'sessionNotice',
);

// Производные провайдеры от состояния
final currentUserProvider = Provider<User?>(
  (ref) => ref.watch(
    authControllerProvider.select(
      (s) => (s is FeatureReady<User>) ? s.data : null,
    ),
  ),
  name: 'currentUser',
);

final isAuthenticatedProvider = Provider<bool>(
  (ref) => ref.watch(authSessionPhaseProvider) == AuthSessionPhase.signedIn,
  name: 'isAuthenticated',
);

final currentUsernameProvider = Provider<String?>(
  (ref) => ref.watch(currentUserProvider)?.username,
  name: 'currentUsername',
);
