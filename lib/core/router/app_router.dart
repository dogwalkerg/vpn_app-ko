// lib/core/router/app_router.dart
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vpn_app/features/auth/providers/auth_providers.dart';
import 'package:vpn_app/features/auth/screens/gate_screen.dart';

import '../../features/auth/screens/login_screen.dart';
import '../../features/auth/screens/register_screen.dart';
import '../../features/auth/screens/verification_screen.dart';
import '../../features/auth/screens/reset_password_screen.dart';
import '../../features/vpn/screens/vpn_screen.dart';
import '../../features/subscription/screens/subscription_screen.dart';
import '../../features/payments/screens/payment_webview_screen.dart';

import 'guards/auth_guard.dart';
import 'routes.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

class RouterNotifier extends ChangeNotifier {
  final Ref ref;
  RouterNotifier(this.ref) {
    ref.listen<bool>(
      isAuthenticatedProvider,
      (previous, next) => notifyListeners(),
    );
  }

  bool get isLoggedIn => ref.read(isAuthenticatedProvider);
}

final routerProvider = Provider<GoRouter>((ref) {
  final notifier = RouterNotifier(ref);

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: AppRoute.gate.path,
    refreshListenable: notifier,
    routes: [
      GoRoute(
        name: AppRoute.gate.name,
        path: AppRoute.gate.path,
        builder: (context, state) => const GateScreen(),
      ),
      GoRoute(
        name: AppRoute.login.name,
        path: AppRoute.login.path,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        name: AppRoute.register.name,
        path: AppRoute.register.path,
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        name: AppRoute.verify.name,
        path: AppRoute.verify.path,
        builder: (_, state) {
          final u = state.uri.queryParameters['u'] ?? '';
          final e = state.uri.queryParameters['e'] ?? '';
          return VerificationScreen(username: u, email: e);
        },
      ),
      GoRoute(
        name: AppRoute.reset.name,
        path: AppRoute.reset.path,
        builder: (_, state) =>
            ResetPasswordScreen(username: state.uri.queryParameters['u'] ?? ''),
      ),
      GoRoute(
        name: AppRoute.vpn.name,
        path: AppRoute.vpn.path,
        builder: (context, state) => const VpnScreen(),
      ),
      GoRoute(
        name: AppRoute.subscription.name,
        path: AppRoute.subscription.path,
        builder: (context, state) => const SubscriptionScreen(),
      ),
      GoRoute(
        name: AppRoute.payment.name,
        path: AppRoute.payment.path,
        builder: (_, state) {
          final extra = state.extra as PaymentWebViewArgs;
          return PaymentWebViewScreen(
            url: extra.url,
            successPrefix: extra.successPrefix,
            cancelPrefix: extra.cancelPrefix,
            onSuccess: extra.onSuccess,
            onCancel: extra.onCancel,
          );
        },
      ),
    ],
    redirect: (ctx, state) {
      final isAuth = notifier.isLoggedIn;

      if (state.matchedLocation == AppRoute.gate.path) {
        return isAuth ? AppRoute.vpn.path : AppRoute.login.path;
      }

      final authRedir = AuthGuard.redirect(
        isAuthenticated: isAuth,
        state: state,
        loginPath: AppRoute.login.path,
        homePath: AppRoute.vpn.path,
      );
      if (authRedir != null) return authRedir;

      return null;
    },
  );
}, name: 'appRouter');
