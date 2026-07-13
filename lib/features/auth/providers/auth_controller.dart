// lib/features/auth/providers/auth_controller.dart
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vpn_app/core/cache/memory_cache.dart';
import 'package:vpn_app/core/models/feature_state.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/traffic/providers/traffic_accounting_provider.dart';
import 'package:vpn_app/features/vpn/providers/subscription_nodes_provider.dart';
import 'package:vpn_app/features/vpn/providers/vpn_controller.dart';
import '../../../core/errors/exceptions.dart';
import '../../../core/storage/secure_storage.dart';
import '../models/domain/user.dart';
import '../repositories/auth_repository_impl.dart';
import '../usecases/login_usecase.dart';
import '../usecases/register_usecase.dart';
import '../usecases/verify_email_usecase.dart';
import '../usecases/validate_token_usecase.dart';
import '../usecases/logout_usecase.dart';
import '../usecases/forgot_password_usecase.dart';
import '../usecases/reset_password_usecase.dart';
import 'auth_providers.dart';

typedef AuthState = FeatureState<User>;

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>(
  (ref) {
    final repo = ref.read(authRepositoryProvider);
    return AuthController(ref, repo);
  },
  name: 'authController',
);

class AuthController extends StateNotifier<AuthState> {
  final MemoryCache<User> _userCache = MemoryCache<User>();
  final Ref ref;
  final LoginUseCase _login;
  final RegisterUseCase _register;
  final VerifyEmailUseCase _verifyEmail;
  final ValidateTokenUseCase _validateToken;
  final LogoutUseCase _logout;
  final ForgotPasswordUseCase _forgotPassword;
  final ResetPasswordUseCase _resetPassword;

  CancelToken? _ct;
  int _authGeneration = 0;

  AuthController(this.ref, repo)
    : _login = LoginUseCase(repo),
      _register = RegisterUseCase(repo),
      _verifyEmail = VerifyEmailUseCase(repo),
      _validateToken = ValidateTokenUseCase(repo),
      _logout = LogoutUseCase(repo),
      _forgotPassword = ForgotPasswordUseCase(repo),
      _resetPassword = ResetPasswordUseCase(repo),
      super(const FeatureIdle()) {
    ref.onDispose(_cancelActive);
    _bootstrap();
  }

  CancelToken _replaceToken() {
    _ct?.cancel('auth:replaced');
    final t = CancelToken();
    _ct = t;
    return t;
  }

  void _cancelActive() {
    final t = _ct;
    if (t != null && !t.isCancelled) {
      t.cancel('auth:dispose');
    }
    _ct = null;
  }

  Future<void> _bootstrap() async {
    final generation = _authGeneration;
    try {
      final token = await AppSecureStorage.readToken();
      if (generation != _authGeneration) return;
      ref.read(tokenProvider.notifier).state = token;

      if (token == null || token.trim().isEmpty) {
        ref.read(authSessionPhaseProvider.notifier).state =
            AuthSessionPhase.signedOut;
        return;
      }

      // Restore the signed-in shell immediately. User and subscription data
      // continue refreshing in the background; only a 401 clears the session.
      ref.read(authSessionPhaseProvider.notifier).state =
          AuthSessionPhase.signedIn;
      unawaited(
        ref
            .read(subscriptionControllerProvider.notifier)
            .fetch(forceRefresh: true),
      );

      final cached = _userCache.value;
      if (cached != null) {
        state = FeatureReady<User>(cached);
        unawaited(_softValidate());
      } else {
        await validateToken();
      }
    } catch (_) {
      if (generation == _authGeneration &&
          ref.read(authSessionPhaseProvider) == AuthSessionPhase.restoring) {
        ref.read(tokenProvider.notifier).state = null;
        ref.read(authSessionPhaseProvider.notifier).state =
            AuthSessionPhase.signedOut;
      }
    }
  }

  Future<void> _softValidate() async {
    final generation = _authGeneration;
    final token = ref.read(tokenProvider);
    try {
      final user = await _validateToken(cancelToken: _replaceToken());
      if (generation != _authGeneration ||
          token == null ||
          ref.read(tokenProvider) != token) {
        return;
      }
      _userCache.set(user);
      state = FeatureReady<User>(user);
      await ref
          .read(subscriptionControllerProvider.notifier)
          .fetch(forceRefresh: true);
      ref.invalidate(subscriptionNodesProvider);
    } on UnauthorizedException {
      if (generation == _authGeneration && ref.read(tokenProvider) == token) {
        await clearLocalSession(notice: '登录已过期，请重新登录');
      }
    } catch (_) {
      // 静默忽略非认证异常。
    }
  }

  bool get isLoading => state.isLoading;
  String? get errorMessage => state.errorMessage;
  bool get isLoggedIn =>
      ref.read(authSessionPhaseProvider) == AuthSessionPhase.signedIn;

  Future<void> login(String username, String password) async {
    final generation = ++_authGeneration;
    state = const FeatureLoading();
    final ct = _replaceToken();
    try {
      final res = await _login(username, password, cancelToken: ct);
      if (generation != _authGeneration || ct.isCancelled) return;
      await AppSecureStorage.saveToken(res.token);
      if (generation != _authGeneration || ct.isCancelled) {
        await AppSecureStorage.clearTokenIfMatches(res.token);
        return;
      }

      ref.read(tokenProvider.notifier).state = res.token;
      ref.read(sessionNoticeProvider.notifier).state = null;
      _userCache.set(res.user);
      state = FeatureReady<User>(res.user);
      ref.read(authSessionPhaseProvider.notifier).state =
          AuthSessionPhase.signedIn;
      unawaited(_refreshAfterLogin(generation, res.token));
    } on ApiException catch (e) {
      if (!ct.isCancelled) state = FeatureError<User>(e.message);
    } catch (_) {
      if (!ct.isCancelled) {
        state = const FeatureError<User>('无法保存登录状态，请重试');
      }
    }
  }

  Future<void> _refreshAfterLogin(int generation, String token) async {
    try {
      await ref
          .read(subscriptionControllerProvider.notifier)
          .fetch(forceRefresh: true);
      if (generation == _authGeneration && ref.read(tokenProvider) == token) {
        ref.invalidate(subscriptionNodesProvider);
      }
    } catch (_) {
      // Authentication succeeded; secondary data can retry from the home page.
    }
  }

  Future<void> register(String username, String email, String password) async {
    state = const FeatureLoading();
    final ct = _replaceToken();
    try {
      await _register(username, email, password, cancelToken: ct);
      state = const FeatureIdle();
    } on ApiException catch (e) {
      if (!ct.isCancelled) state = FeatureError<User>(e.message);
    }
  }

  Future<void> verifyEmail(String username, String email, String code) async {
    state = const FeatureLoading();
    final ct = _replaceToken();
    try {
      await _verifyEmail(username, email, code, cancelToken: ct);
      state = const FeatureIdle();
    } on ApiException catch (e) {
      if (!ct.isCancelled) state = FeatureError<User>(e.message);
    }
  }

  Future<void> validateToken() async {
    final generation = _authGeneration;
    final token = ref.read(tokenProvider);
    state = const FeatureLoading();
    final ct = _replaceToken();
    try {
      final user = await _validateToken(cancelToken: ct);
      if (generation != _authGeneration ||
          token == null ||
          ref.read(tokenProvider) != token ||
          ct.isCancelled) {
        return;
      }
      _userCache.set(user);
      state = FeatureReady<User>(user);
      await ref
          .read(subscriptionControllerProvider.notifier)
          .fetch(forceRefresh: true);
      ref.invalidate(subscriptionNodesProvider);
    } on UnauthorizedException {
      if (generation == _authGeneration && ref.read(tokenProvider) == token) {
        await clearLocalSession(notice: '登录已过期，请重新登录');
      }
    } on ApiException catch (e) {
      if (!ct.isCancelled) state = FeatureError<User>(e.message);
    }
  }

  Future<bool> logout({bool silent = false}) async {
    _authGeneration++;
    final previousState = state;
    if (!silent) state = const FeatureLoading();
    final ct = _replaceToken();
    try {
      if (!await ref.read(trafficFlushProvider)()) {
        if (!silent) state = previousState;
        return false;
      }
      await ref.read(vpnControllerProvider.notifier).disconnectPressed();
      if (!await ref.read(trafficFlushProvider)()) {
        if (!silent) state = previousState;
        return false;
      }
    } catch (_) {
      if (!silent) state = previousState;
      return false;
    }
    try {
      await _logout(cancelToken: ct);
    } catch (_) {}
    await clearLocalSession();
    return true;
  }

  /// Clears only local authentication state.
  ///
  /// This is used when the backend has already rejected the session. It must
  /// not call the logout endpoint or alter the VPN connection; those actions
  /// belong to the caller so restriction handling cannot recurse.
  Future<void> clearLocalSession({String? notice}) async {
    _authGeneration++;
    _cancelActive();
    _userCache.clear();
    ref.read(tokenProvider.notifier).state = null;
    ref.read(authSessionPhaseProvider.notifier).state =
        AuthSessionPhase.signedOut;
    if (notice != null && notice.trim().isNotEmpty) {
      ref.read(sessionNoticeProvider.notifier).state = notice.trim();
    }
    await AppSecureStorage.clearToken();
    await ref.read(subscriptionControllerProvider.notifier).clearCache();

    ref.invalidate(subscriptionControllerProvider);
    ref.invalidate(subscriptionNodesProvider);
    ref.read(selectedSubscriptionNodeProvider.notifier).state = null;

    state = const FeatureIdle();
  }

  Future<void> forgotPassword(String username) async {
    state = const FeatureLoading();
    final ct = _replaceToken();
    try {
      await _forgotPassword(username, cancelToken: ct);
      state = const FeatureIdle();
    } on ApiException catch (e) {
      if (!ct.isCancelled) state = FeatureError<User>(e.message);
    }
  }

  Future<void> resetPassword(
    String username,
    String resetCode,
    String newPassword,
  ) async {
    state = const FeatureLoading();
    final ct = _replaceToken();
    try {
      await _resetPassword(username, resetCode, newPassword, cancelToken: ct);
      state = const FeatureIdle();
    } on ApiException catch (e) {
      if (!ct.isCancelled) state = FeatureError<User>(e.message);
    }
  }
}
