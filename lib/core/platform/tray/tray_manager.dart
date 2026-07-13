// lib/core/platform/tray/tray_manager.dart
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:vpn_app/features/auth/providers/auth_providers.dart';
import 'package:vpn_app/features/vpn/providers/vpn_controller.dart';
import 'package:vpn_app/features/vpn/usecases/disconnect_with_traffic.dart';
import 'package:vpn_app/features/traffic/providers/traffic_accounting_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../router/app_router.dart';
import 'package:logger/logger.dart';

final logger = Logger();

class TrayManagerHandler with tray.TrayListener {
  TrayManagerHandler() {
    _initializeTray();
  }

  bool _isInitialized = false;

  Future<void> _initializeTray() async {
    if (_isInitialized) return;
    _isInitialized = true;
    await tray.TrayManager.instance.setIcon(
      'assets/tray/tray_icon_disconnect.ico',
    );
    tray.TrayManager.instance.addListener(this);
  }

  Future<void> updateTrayIconAndMenu() async {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return;

    final container = ProviderScope.containerOf(context);
    final vpnState = container.read(vpnControllerProvider);
    final isLoggedIn = container.read(isAuthenticatedProvider);

    final bool isConnected = vpnState is VpnConnected;
    final bool isConnecting =
        vpnState is VpnConnecting || vpnState is VpnDisconnecting;
    final menu = tray.Menu(
      items: [
        tray.MenuItem(key: 'show_window', label: '显示窗口'),
        tray.MenuItem.separator(),
        tray.MenuItem(
          key: 'connect',
          label: '连接',
          disabled: !isLoggedIn || isConnected || isConnecting,
        ),
        tray.MenuItem(
          key: 'disconnect',
          label: '断开连接',
          disabled: !isLoggedIn || !isConnected,
        ),
        tray.MenuItem.separator(),
        tray.MenuItem(key: 'exit', label: '退出应用'),
      ],
    );
    await tray.TrayManager.instance.setContextMenu(menu);
    final iconPath = isConnected
        ? 'assets/tray/tray_icon_connect.ico'
        : 'assets/tray/tray_icon_disconnect.ico';
    await tray.TrayManager.instance.setIcon(iconPath);
  }

  @override
  void onTrayIconRightMouseDown() {
    updateTrayIconAndMenu();
    tray.TrayManager.instance.popUpContextMenu();
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
  }

  @override
  void onTrayMenuItemClick(tray.MenuItem menuItem) async {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return;

    final container = ProviderScope.containerOf(context);
    final vpn = container.read(vpnControllerProvider.notifier);
    final vpnState = container.read(vpnControllerProvider);
    final isLoggedIn = container.read(isAuthenticatedProvider);

    final bool isConnected = vpnState is VpnConnected;
    final bool isConnecting =
        vpnState is VpnConnecting || vpnState is VpnDisconnecting;

    switch (menuItem.key) {
      case 'show_window':
        windowManager.show();
        break;
      case 'connect':
        if (!isLoggedIn || isConnected || isConnecting) return;
        try {
          await vpn.connectPressed();
        } catch (e) {
          logger.e('托盘连接失败: $e');
        }
        break;
      case 'disconnect':
        try {
          final accounting = container.read(trafficAccountingProvider.notifier);
          await disconnectWithTrafficSync(
            flushTraffic: accounting.flush,
            disconnectVpn: vpn.disconnectPressed,
          );
        } catch (e) {
          logger.e('托盘断开失败: $e');
        }
        break;
      case 'exit':
        try {
          final accounting = container.read(trafficAccountingProvider.notifier);
          await disconnectWithTrafficSync(
            flushTraffic: accounting.flush,
            disconnectVpn: vpn.disconnectPressed,
          );
        } catch (e) {
          logger.e('断开连接失败: $e');
        }
        tray.TrayManager.instance.destroy();
        windowManager.destroy();
        break;
    }
    logger.i('Menu item clicked: ${menuItem.key}');
  }

  void dispose() {
    tray.TrayManager.instance.removeListener(this);
    _isInitialized = false;
  }
}

late TrayManagerHandler trayHandler;
