// lib/core/router/guards/auth_guard.dart
import 'package:go_router/go_router.dart';

class AuthGuard {
  static const Set<String> publicPaths = {
    '/gate',
    '/login',
    '/register',
    '/verify',
    '/reset',
  };

  static bool _isPublic(GoRouterState state) {
    final loc = state.matchedLocation;
    return publicPaths.any((p) => loc == p || loc.startsWith('$p/'));
  }

  static String? redirect({
    required bool isSessionRestoring,
    required bool isAuthenticated,
    required GoRouterState state,
    String gatePath = '/gate',
    String loginPath = '/login',
    String homePath = '/vpn',
  }) {
    if (isSessionRestoring) {
      return state.matchedLocation == gatePath ? null : gatePath;
    }

    if (state.matchedLocation == gatePath) {
      return isAuthenticated ? homePath : loginPath;
    }

    final goingPublic = _isPublic(state);

    if (!isAuthenticated && !goingPublic) {
      return loginPath;
    }

    if (isAuthenticated && state.matchedLocation == loginPath) {
      return homePath;
    }

    return null;
  }
}
