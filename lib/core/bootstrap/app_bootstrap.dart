// lib/core/bootstrap/app_bootstrap.dart
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpn_app/core/providers/provider_observer.dart';
import 'package:vpn_app/core/storage/secure_storage.dart';
import 'package:vpn_app/core/storage/shared_preferences_provider.dart';
import 'package:vpn_app/features/auth/providers/auth_providers.dart';
import 'package:window_manager/window_manager.dart';

import '../monitoring/error_reporter.dart';
import '../router/app_router.dart';
import '../../ui/theme/light_theme.dart';
import '../platform/tray/tray_manager.dart';
import '../network/connectivity_provider.dart';
import '../../features/payments/deeplink/deeplink_handler.dart';
import '../../features/traffic/providers/traffic_accounting_provider.dart';

class AppBootstrap {
  static Future<void> run() async {
    WidgetsFlutterBinding.ensureInitialized();
    final sharedPreferences = await SharedPreferences.getInstance();
    final localAuthSession = AppSecureStorage.readLocalSession(
      sharedPreferences,
    );
    final initialSessionPhase = initialAuthSessionPhase(
      localStoreInitialized: localAuthSession.initialized,
      token: localAuthSession.token,
    );

    // Desktop окно/трей
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
      trayHandler = TrayManagerHandler();
      windowManager.addListener(_MyWindowListener());
      const windowOptions = WindowOptions(center: true, skipTaskbar: false);
      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
      });
    }

    // Мониторинг — пока логгером, но единая точка для будущего Sentry/Crashlytics
    installGlobalErrorHandlers(LogOnlyErrorReporter());

    // Запуск приложения
    runApp(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(sharedPreferences),
          tokenProvider.overrideWith((ref) => localAuthSession.token),
          authSessionPhaseProvider.overrideWith((ref) => initialSessionPhase),
        ],
        observers: [AppProviderObserver()],
        child: _Bootstrap(child: const _MyApp()),
      ),
    );
  }
}

/// Прелоад ассетов/инициализация на первом кадре
class _Bootstrap extends ConsumerStatefulWidget {
  final Widget child;
  const _Bootstrap({required this.child});

  @override
  ConsumerState<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends ConsumerState<_Bootstrap> {
  bool _assetsPrecached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Прелоад ассетов
    if (!_assetsPrecached) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          if (mounted) {
            await precacheImage(
              const AssetImage('assets/background.png'),
              context,
            );
          }
        } catch (_) {
          /* ignore */
        }
      });
      _assetsPrecached = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Включаем side-effects провайдеров (просто наблюдаем)
    ref.watch(
      swrRefreshOnReconnectProvider,
    ); // SWR refresh при восстановлении сети
    ref.watch(paymentDeeplinkInitializerProvider); // слушатель диплинков оплаты
    ref.watch(
      trafficAccountingProvider,
    ); // global traffic accounting and account heartbeat
    return widget.child;
  }
}

class _MyApp extends ConsumerWidget {
  const _MyApp();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Osca',
      theme: appLightTheme,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      scrollBehavior: const _AppScrollBehavior(),
    );
  }
}

class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}

class _MyWindowListener extends WindowListener {
  @override
  void onWindowClose() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await windowManager.hide();
    }
  }
}
