import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpn_app/core/api/api_service.dart';
import 'package:vpn_app/core/router/app_router.dart';
import 'package:vpn_app/features/auth/models/domain/login_result.dart';
import 'package:vpn_app/features/auth/models/domain/user.dart';
import 'package:vpn_app/features/auth/providers/auth_providers.dart';
import 'package:vpn_app/features/auth/repositories/auth_repository.dart';
import 'package:vpn_app/features/auth/repositories/auth_repository_impl.dart';
import 'package:vpn_app/features/auth/screens/gate_screen.dart';
import 'package:vpn_app/features/auth/screens/login_screen.dart';
import 'package:vpn_app/features/subscription/models/subscription_status.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/subscription/repositories/subscription_repository.dart';
import 'package:vpn_app/features/vpn/providers/subscription_nodes_provider.dart';
import 'package:vpn_app/features/vpn/screens/vpn_screen.dart';
import 'package:vpn_app/features/vpn/usecases/connect_vpn_usecase.dart';
import 'package:vpn_app/features/vpn/usecases/disconnect_vpn_usecase.dart';
import 'package:vpn_app/features/vpn/usecases/is_connected_usecase.dart';
import 'package:vpn_app/ui/theme/light_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cached auth state maps to a signed-in first frame', () {
    expect(
      initialAuthSessionPhase(
        localStoreInitialized: true,
        token: 'cached-token',
      ),
      AuthSessionPhase.signedIn,
    );
    expect(
      initialAuthSessionPhase(localStoreInitialized: true, token: null),
      AuthSessionPhase.signedOut,
    );
    expect(
      initialAuthSessionPhase(localStoreInitialized: false, token: null),
      AuthSessionPhase.restoring,
    );
  });

  testWidgets('router follows signed-out, signed-in, and signed-out phases', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'auth_token_store_initialized_v1': true,
    });
    final mounted = await _mountRouter(tester);
    addTearDown(() => mounted.dispose(tester));

    await _pumpUntil(
      tester,
      () =>
          mounted.container.read(authSessionPhaseProvider) ==
              AuthSessionPhase.signedOut &&
          mounted.location == '/login',
    );

    expect(find.byType(LoginScreen), findsOneWidget);

    mounted.container.read(authSessionPhaseProvider.notifier).state =
        AuthSessionPhase.signedIn;
    await _pumpUntil(tester, () => mounted.location == '/vpn');

    expect(find.byType(LoginScreen), findsNothing);
    expect(find.byType(VpnScreen), findsOneWidget);

    mounted.container.read(authSessionPhaseProvider.notifier).state =
        AuthSessionPhase.signedOut;
    await _pumpUntil(tester, () => mounted.location == '/login');

    expect(find.byType(VpnScreen), findsNothing);
    expect(find.byType(LoginScreen), findsOneWidget);

    await mounted.dispose(tester);
  });

  testWidgets('restoring a signed-in session never renders the login route', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final originalStorage = FlutterSecureStoragePlatform.instance;
    final controlledStorage = _ControlledSecureStorage();
    FlutterSecureStoragePlatform.instance = controlledStorage;
    addTearDown(() => FlutterSecureStoragePlatform.instance = originalStorage);

    final mounted = await _mountRouter(tester);
    addTearDown(() => mounted.dispose(tester));

    expect(
      mounted.container.read(authSessionPhaseProvider),
      AuthSessionPhase.restoring,
    );
    expect(mounted.location, '/gate');
    expect(find.byType(GateScreen), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);

    controlledStorage.completeRead('persisted-token');

    var reachedVpn = false;
    for (var frame = 0; frame < 50; frame++) {
      await tester.pump(const Duration(milliseconds: 10));
      expect(
        find.byType(LoginScreen),
        findsNothing,
        reason: 'The login page flashed while the stored session restored',
      );
      if (mounted.location == '/vpn') {
        reachedVpn = true;
        break;
      }
    }

    // Let Navigator finish replacing GateScreen while checking every
    // transition frame for the regression this test is intended to catch.
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byType(LoginScreen),
        findsNothing,
        reason: 'The login page flashed during the route transition',
      );
    }

    expect(reachedVpn, isTrue, reason: 'The restored session never opened vpn');
    expect(
      mounted.container.read(authSessionPhaseProvider),
      AuthSessionPhase.signedIn,
    );
    expect(find.byType(VpnScreen), findsOneWidget);

    await mounted.dispose(tester);
  });
}

Future<_MountedRouter> _mountRouter(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(430, 1100));

  final dio = Dio();
  final container = ProviderContainer(
    overrides: [
      apiServiceProvider.overrideWithValue(ApiService(dio)),
      authRepositoryProvider.overrideWithValue(_StubAuthRepository()),
      subscriptionRepositoryProvider.overrideWithValue(
        _StubSubscriptionRepository(),
      ),
      subscriptionNodesProvider.overrideWith((ref) async => const []),
      currentUsernameProvider.overrideWithValue('tester'),
      connectVpnUseCaseProvider.overrideWithValue(() async {}),
      disconnectVpnUseCaseProvider.overrideWithValue(() async {}),
      isVpnConnectedUseCaseProvider.overrideWithValue(() async => false),
    ],
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const _RouterTestApp(),
    ),
  );

  return _MountedRouter(container: container, dio: dio);
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() predicate) async {
  for (var frame = 0; frame < 50; frame++) {
    if (predicate()) {
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      return;
    }
    await tester.pump(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for the expected router state');
}

class _RouterTestApp extends ConsumerWidget {
  const _RouterTestApp();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      theme: appLightTheme,
      routerConfig: ref.watch(routerProvider),
    );
  }
}

class _MountedRouter {
  _MountedRouter({required this.container, required this.dio});

  final ProviderContainer container;
  final Dio dio;
  bool _disposed = false;

  String get location =>
      container.read(routerProvider).routeInformationProvider.value.uri.path;

  Future<void> dispose(WidgetTester tester) async {
    if (_disposed) return;
    _disposed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    dio.close(force: true);
    await tester.binding.setSurfaceSize(null);
  }
}

class _StubAuthRepository implements AuthRepository {
  static const user = User(username: 'tester', email: 'tester@example.com');

  @override
  Future<User> validateToken({CancelToken? cancelToken}) async => user;

  @override
  Future<LoginResult> login({
    required String username,
    required String password,
    CancelToken? cancelToken,
  }) async => const LoginResult(token: 'login-token', user: user);

  @override
  Future<void> logout({CancelToken? cancelToken}) async {}

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
  static const status = SubscriptionStatus(
    isTrial: false,
    isPaid: true,
    canUse: true,
    deviceCount: 0,
    maxDevices: 3,
  );

  @override
  SubscriptionStatus? getCached() => null;

  @override
  bool isCacheFresh() => false;

  @override
  Future<SubscriptionStatus> fetchFresh({CancelToken? cancelToken}) async =>
      status;

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

class _ControlledSecureStorage extends FlutterSecureStoragePlatform {
  final Completer<String?> _readCompleter = Completer<String?>();

  void completeRead(String? token) => _readCompleter.complete(token);

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
  }) {
    if (key == 'auth_session_state_v2') return Future<String?>.value();
    return _readCompleter.future;
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => const {};

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {}
}
