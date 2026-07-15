import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpn_app/core/errors/exceptions.dart';
import 'package:vpn_app/core/models/feature_state.dart';
import 'package:vpn_app/core/storage/secure_storage.dart';
import 'package:vpn_app/features/auth/models/domain/login_result.dart';
import 'package:vpn_app/features/auth/models/domain/user.dart';
import 'package:vpn_app/features/auth/providers/auth_providers.dart';
import 'package:vpn_app/features/auth/repositories/auth_repository.dart';
import 'package:vpn_app/features/auth/repositories/auth_repository_impl.dart';
import 'package:vpn_app/features/subscription/models/subscription_status.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/subscription/repositories/subscription_repository.dart';
import 'package:vpn_app/features/traffic/providers/traffic_accounting_provider.dart';
import 'package:vpn_app/features/vpn/providers/subscription_nodes_provider.dart';
import 'package:vpn_app/features/vpn/providers/vpn_controller.dart';
import 'package:vpn_app/features/vpn/usecases/connect_vpn_usecase.dart';
import 'package:vpn_app/features/vpn/usecases/disconnect_vpn_usecase.dart';
import 'package:vpn_app/features/vpn/usecases/is_connected_usecase.dart';

void main() {
  const user = User(username: 'tester', email: 'tester@example.com');

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'successful login persists token before publishing signed-in state',
    () async {
      final authRepository = _StubAuthRepository(user: user);
      final container = _container(authRepository, disconnect: () async {});
      addTearDown(container.dispose);

      container.read(authControllerProvider);
      await _waitUntil(
        () =>
            container.read(authSessionPhaseProvider) ==
            AuthSessionPhase.signedOut,
      );

      await container
          .read(authControllerProvider.notifier)
          .login('tester', 'password');

      expect(authRepository.loginCalls, 1);
      expect(await AppSecureStorage.readToken(), 'login-token');
      expect(container.read(tokenProvider), 'login-token');
      expect(
        container.read(authSessionPhaseProvider),
        AuthSessionPhase.signedIn,
      );
      expect(container.read(authControllerProvider), isA<FeatureReady<User>>());
    },
  );

  test(
    'subscription refresh failure does not undo a successful login',
    () async {
      final authRepository = _StubAuthRepository(user: user);
      final container = _container(
        authRepository,
        disconnect: () async {},
        subscriptionRepository: _StubSubscriptionRepository(
          fetchError: const ApiException('offline'),
        ),
      );
      addTearDown(container.dispose);

      container.read(authControllerProvider);
      await _waitUntil(
        () =>
            container.read(authSessionPhaseProvider) ==
            AuthSessionPhase.signedOut,
      );
      await container
          .read(authControllerProvider.notifier)
          .login('tester', 'password');
      await Future<void>.delayed(Duration.zero);

      expect(await AppSecureStorage.readToken(), 'login-token');
      expect(container.read(tokenProvider), 'login-token');
      expect(
        container.read(authSessionPhaseProvider),
        AuthSessionPhase.signedIn,
      );
      expect(container.read(authControllerProvider), isA<FeatureReady<User>>());
    },
  );

  test(
    'hanging platform secure storage does not block a successful login',
    () async {
      final original = FlutterSecureStoragePlatform.instance;
      addTearDown(() => FlutterSecureStoragePlatform.instance = original);
      FlutterSecureStoragePlatform.instance = _HangingWriteSecureStorage();
      SharedPreferences.setMockInitialValues({
        'auth_token_store_initialized_v1': true,
      });
      final authRepository = _StubAuthRepository(user: user);
      final container = _container(authRepository, disconnect: () async {});
      addTearDown(container.dispose);

      container.read(authControllerProvider);
      await _waitUntil(
        () =>
            container.read(authSessionPhaseProvider) ==
            AuthSessionPhase.signedOut,
      );

      await container
          .read(authControllerProvider.notifier)
          .login('tester', 'password')
          .timeout(const Duration(milliseconds: 500));

      expect(await AppSecureStorage.readToken(), 'login-token');
      expect(container.read(tokenProvider), 'login-token');
      expect(
        container.read(authSessionPhaseProvider),
        AuthSessionPhase.signedIn,
      );
      expect(container.read(authControllerProvider), isA<FeatureReady<User>>());
    },
  );

  test(
    'persisted token restores the signed-in session before validation',
    () async {
      FlutterSecureStorage.setMockInitialValues({'token': 'stored-token'});
      final validation = Completer<User>();
      final authRepository = _StubAuthRepository(
        user: user,
        validation: validation,
      );
      final container = _container(authRepository, disconnect: () async {});
      addTearDown(container.dispose);

      container.read(authControllerProvider);
      await _waitUntil(() => authRepository.validateCalls == 1);

      expect(container.read(tokenProvider), 'stored-token');
      expect(
        container.read(authSessionPhaseProvider),
        AuthSessionPhase.signedIn,
      );
      expect(container.read(isAuthenticatedProvider), isTrue);

      validation.complete(user);
      await _waitUntil(
        () => container.read(authControllerProvider) is FeatureReady<User>,
      );
    },
  );

  test('missing persisted token completes startup as signed out', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final authRepository = _StubAuthRepository(user: user);
    final container = _container(authRepository, disconnect: () async {});
    addTearDown(container.dispose);

    container.read(authControllerProvider);
    await _waitUntil(
      () =>
          container.read(authSessionPhaseProvider) ==
          AuthSessionPhase.signedOut,
    );

    expect(container.read(tokenProvider), isNull);
    expect(container.read(isAuthenticatedProvider), isFalse);
    expect(authRepository.validateCalls, 0);
  });

  test(
    'temporary validation failure keeps the persisted session signed in',
    () async {
      FlutterSecureStorage.setMockInitialValues({'token': 'stored-token'});
      final authRepository = _StubAuthRepository(
        user: user,
        validationError: const ApiException('offline'),
      );
      final container = _container(authRepository, disconnect: () async {});
      addTearDown(container.dispose);

      container.read(authControllerProvider);
      await _waitUntil(
        () => container.read(authControllerProvider) is FeatureError<User>,
      );

      expect(container.read(tokenProvider), 'stored-token');
      expect(
        container.read(authSessionPhaseProvider),
        AuthSessionPhase.signedIn,
      );
      expect(container.read(isAuthenticatedProvider), isTrue);
      expect(await AppSecureStorage.readToken(), 'stored-token');
    },
  );

  test('clearLocalSession does not call the backend or VPN', () async {
    FlutterSecureStorage.setMockInitialValues({'token': 'stored-token'});
    final authRepository = _StubAuthRepository(user: user);
    var disconnectCalls = 0;
    final container = _container(
      authRepository,
      disconnect: () async => disconnectCalls++,
    );
    addTearDown(container.dispose);

    await _waitUntil(
      () => container.read(authControllerProvider) is FeatureReady<User>,
    );

    await container
        .read(authControllerProvider.notifier)
        .clearLocalSession(notice: '账户已禁用');

    expect(container.read(authControllerProvider), isA<FeatureIdle<User>>());
    expect(container.read(tokenProvider), isNull);
    expect(container.read(sessionNoticeProvider), '账户已禁用');
    expect(await AppSecureStorage.readToken(), isNull);
    expect(authRepository.logoutCalls, 0);
    expect(disconnectCalls, 0);
  });

  test('unauthorized validation expires only the local session', () async {
    FlutterSecureStorage.setMockInitialValues({'token': 'expired-token'});
    final authRepository = _StubAuthRepository(
      user: user,
      validationError: const UnauthorizedException('expired'),
    );
    var disconnectCalls = 0;
    final container = _container(
      authRepository,
      disconnect: () async => disconnectCalls++,
    );
    addTearDown(container.dispose);

    container.read(authControllerProvider);
    await _waitUntil(
      () =>
          authRepository.validateCalls > 0 &&
          container.read(tokenProvider) == null,
    );

    expect(container.read(authControllerProvider), isA<FeatureIdle<User>>());
    expect(await AppSecureStorage.readToken(), isNull);
    expect(authRepository.logoutCalls, 0);
    expect(disconnectCalls, 0);
  });

  test(
    'clearLocalSession cancels validation and ignores its delayed success',
    () async {
      FlutterSecureStorage.setMockInitialValues({'token': 'stored-token'});
      final validation = Completer<User>();
      final authRepository = _StubAuthRepository(
        user: user,
        validation: validation,
      );
      final container = _container(authRepository, disconnect: () async {});
      addTearDown(container.dispose);

      container.read(authControllerProvider);
      await _waitUntil(() => authRepository.validateCalls == 1);

      final validationToken = authRepository.lastValidationToken;
      expect(validationToken, isNotNull);
      expect(validationToken!.isCancelled, isFalse);

      await container.read(authControllerProvider.notifier).clearLocalSession();

      expect(validationToken.isCancelled, isTrue);
      validation.complete(user);
      await validation.future;
      await Future<void>.delayed(Duration.zero);

      expect(container.read(authControllerProvider), isA<FeatureIdle<User>>());
      expect(container.read(tokenProvider), isNull);
      expect(await AppSecureStorage.readToken(), isNull);
    },
  );

  test(
    'logout keeps disconnect and remote logout before local cleanup',
    () async {
      FlutterSecureStorage.setMockInitialValues({'token': 'stored-token'});
      final events = <String>[];
      final authRepository = _StubAuthRepository(
        user: user,
        onLogout: () => events.add('remote-logout'),
      );
      final container = _container(
        authRepository,
        disconnect: () async => events.add('disconnect'),
      );
      addTearDown(container.dispose);

      await _waitUntil(
        () => container.read(authControllerProvider) is FeatureReady<User>,
      );

      expect(
        await container.read(authControllerProvider.notifier).logout(),
        isTrue,
      );

      expect(events, ['disconnect', 'remote-logout']);
      expect(container.read(authControllerProvider), isA<FeatureIdle<User>>());
      expect(container.read(tokenProvider), isNull);
      expect(await AppSecureStorage.readToken(), isNull);
    },
  );

  test(
    'local cleanup stays behind the restoring gate until persistence finishes',
    () async {
      final original = FlutterSecureStoragePlatform.instance;
      addTearDown(() => FlutterSecureStoragePlatform.instance = original);
      FlutterSecureStoragePlatform.instance = _HangingWriteSecureStorage();
      SharedPreferences.setMockInitialValues({
        'auth_token_store_initialized_v1': true,
        'auth_token_fallback_v1': 'stored-token',
      });
      final authRepository = _StubAuthRepository(user: user);
      final container = _container(authRepository, disconnect: () async {});
      addTearDown(container.dispose);

      await _waitUntil(
        () => container.read(authControllerProvider) is FeatureReady<User>,
      );

      final cleanup = container
          .read(authControllerProvider.notifier)
          .clearLocalSession();
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(authSessionPhaseProvider),
        AuthSessionPhase.restoring,
      );
      expect(container.read(tokenProvider), 'stored-token');
      expect(await cleanup, isTrue);
      expect(
        container.read(authSessionPhaseProvider),
        AuthSessionPhase.signedOut,
      );
      expect(container.read(tokenProvider), isNull);
    },
  );

  test(
    'logout fails closed when backend and secure cleanup both fail',
    () async {
      final original = FlutterSecureStoragePlatform.instance;
      addTearDown(() => FlutterSecureStoragePlatform.instance = original);
      FlutterSecureStoragePlatform.instance = _UnavailableSecureStorage();
      SharedPreferences.setMockInitialValues({
        'auth_session_v2': '{"state":"signed_in","token":"stored-token"}',
      });
      final authRepository = _StubAuthRepository(
        user: user,
        logoutError: const ApiException('offline'),
      );
      final container = _container(authRepository, disconnect: () async {});
      addTearDown(container.dispose);

      await _waitUntil(
        () => container.read(authControllerProvider) is FeatureReady<User>,
      );

      expect(
        await container.read(authControllerProvider.notifier).logout(),
        isFalse,
      );
      expect(
        container.read(authSessionPhaseProvider),
        AuthSessionPhase.signedIn,
      );
      expect(container.read(tokenProvider), 'stored-token');
      expect(container.read(authControllerProvider), isA<FeatureError<User>>());
    },
  );
}

ProviderContainer _container(
  _StubAuthRepository authRepository, {
  required Future<void> Function() disconnect,
  _StubSubscriptionRepository? subscriptionRepository,
}) {
  return ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(authRepository),
      subscriptionRepositoryProvider.overrideWithValue(
        subscriptionRepository ?? _StubSubscriptionRepository(),
      ),
      subscriptionNodesProvider.overrideWith((ref) async => const []),
      vpnControllerProvider.overrideWith(
        (ref) => _StubVpnController(ref, disconnect),
      ),
      connectVpnUseCaseProvider.overrideWithValue(() async {}),
      disconnectVpnUseCaseProvider.overrideWithValue(disconnect),
      isVpnConnectedUseCaseProvider.overrideWithValue(() async => false),
      trafficFlushProvider.overrideWithValue(() async => true),
    ],
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for provider state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _StubVpnController extends VpnController {
  _StubVpnController(Ref ref, this.onDisconnect)
    : super(
        connect: () async {},
        disconnect: () async {},
        isConnected: () async => false,
        ref: ref,
      );

  final Future<void> Function() onDisconnect;

  @override
  Future<void> disconnectPressed() => onDisconnect();
}

class _StubAuthRepository implements AuthRepository {
  _StubAuthRepository({
    required this.user,
    this.validationError,
    this.validation,
    this.onLogout,
    this.logoutError,
  });

  final User user;
  final Object? validationError;
  final Completer<User>? validation;
  final void Function()? onLogout;
  final Object? logoutError;
  int validateCalls = 0;
  int loginCalls = 0;
  int logoutCalls = 0;
  CancelToken? lastValidationToken;

  @override
  Future<User> validateToken({CancelToken? cancelToken}) async {
    validateCalls++;
    lastValidationToken = cancelToken;
    if (validationError case final error?) throw error;
    if (validation case final pending?) return pending.future;
    return user;
  }

  @override
  Future<void> logout({CancelToken? cancelToken}) async {
    logoutCalls++;
    onLogout?.call();
    if (logoutError case final error?) throw error;
  }

  @override
  Future<LoginResult> login({
    required String username,
    required String password,
    CancelToken? cancelToken,
  }) async {
    loginCalls++;
    return LoginResult(token: 'login-token', user: user);
  }

  @override
  Future<void> register({
    required String username,
    required String email,
    required String password,
    CancelToken? cancelToken,
  }) => throw UnimplementedError();

  @override
  Future<void> verifyEmail({
    required String username,
    required String email,
    required String verificationCode,
    CancelToken? cancelToken,
  }) => throw UnimplementedError();

  @override
  Future<void> forgotPassword(String username, {CancelToken? cancelToken}) =>
      throw UnimplementedError();

  @override
  Future<void> resetPassword({
    required String username,
    required String resetCode,
    required String newPassword,
    CancelToken? cancelToken,
  }) => throw UnimplementedError();
}

class _StubSubscriptionRepository implements SubscriptionRepository {
  _StubSubscriptionRepository({this.fetchError});

  final Object? fetchError;

  static const status = SubscriptionStatus(
    isTrial: false,
    isPaid: true,
    canUse: true,
    deviceCount: 0,
    maxDevices: 0,
  );

  @override
  SubscriptionStatus? getCached() => null;

  @override
  bool isCacheFresh() => false;

  @override
  Future<SubscriptionStatus> fetchFresh({CancelToken? cancelToken}) async {
    if (fetchError case final error?) throw error;
    return status;
  }

  @override
  Future<SubscriptionStatus?> applyTrafficSnapshot({
    required int total,
    required int used,
    bool? canUse,
    String? paidUntil,
    String? subUrl,
    String? updatedAt,
  }) async => status;

  @override
  Future<SubscriptionStatus?> markBlocked() async =>
      status.copyWith(canUse: false);

  @override
  Future<void> clearCache() async {}
}

class _HangingWriteSecureStorage extends FlutterSecureStoragePlatform {
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
  }) async {}

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {}

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
