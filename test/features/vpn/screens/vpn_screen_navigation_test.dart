import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/api/api_service.dart';
import 'package:vpn_app/features/auth/providers/auth_providers.dart';
import 'package:vpn_app/features/vpn/models/subscription_node.dart';
import 'package:vpn_app/features/vpn/providers/subscription_nodes_provider.dart';
import 'package:vpn_app/features/vpn/screens/vpn_screen.dart';
import 'package:vpn_app/features/vpn/usecases/connect_vpn_usecase.dart';
import 'package:vpn_app/features/vpn/usecases/disconnect_vpn_usecase.dart';
import 'package:vpn_app/features/vpn/usecases/is_connected_usecase.dart';
import 'package:vpn_app/ui/theme/light_theme.dart';

void main() {
  test('automatic subscription refresh uses the quota-safe interval', () {
    expect(subscriptionAutoRefreshInterval, const Duration(hours: 1));
    expect(
      shouldRunAutomaticSubscriptionRefresh(
        appIsForeground: false,
        desktopWindowVisible: true,
      ),
      isFalse,
    );
    expect(
      shouldRunAutomaticSubscriptionRefresh(
        appIsForeground: true,
        desktopWindowVisible: false,
      ),
      isFalse,
    );
    expect(
      shouldRunAutomaticSubscriptionRefresh(
        appIsForeground: true,
        desktopWindowVisible: true,
      ),
      isTrue,
    );
  });

  const node = SubscriptionNode(
    name: 'CFB电信优选1',
    type: 'VLESS',
    host: '127.0.0.1',
    port: 1,
    country: 'China',
    flag: '',
    speedMbps: 0,
    load: 0,
    raw: 'vless://test@127.0.0.1:1#CFB电信优选1',
  );

  testWidgets(
    'main tabs have no drawer and settings only show supported actions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final dio = Dio();
      addTearDown(() => dio.close(force: true));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiServiceProvider.overrideWithValue(ApiService(dio)),
            currentUsernameProvider.overrideWithValue('test-user'),
            connectVpnUseCaseProvider.overrideWithValue(() async {}),
            disconnectVpnUseCaseProvider.overrideWithValue(() async {}),
            isVpnConnectedUseCaseProvider.overrideWithValue(() async => false),
            subscriptionNodesProvider.overrideWith((ref) async => const [node]),
            selectedSubscriptionNodeProvider.overrideWith((ref) => node),
            nodeLatencyProbeProvider.overrideWithValue((_) async => 42),
          ],
          child: MaterialApp(theme: appLightTheme, home: const VpnScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();

      _expectNoMenuOrDrawer(tester);
      expect(find.text('线路质量：★★★★★'), findsOneWidget);
      expect(find.textContaining('${node.host}:${node.port}'), findsNothing);

      await tester.tap(find.byTooltip('线路'));
      await tester.pump();
      expect(find.text('选择线路'), findsOneWidget);
      expect(find.textContaining('线路质量：★★★★★'), findsNWidgets(2));
      expect(find.textContaining('接入延迟：42 ms'), findsOneWidget);
      expect(find.textContaining('连接时验证出口'), findsNothing);
      expect(find.textContaining('${node.host}:${node.port}'), findsNothing);
      _expectNoMenuOrDrawer(tester);

      await tester.tap(find.byTooltip('设置'));
      await tester.pump();

      for (final title in const ['会员中心与续费', '每日签到', '公告', '帮助', '退出账号']) {
        expect(find.text(title), findsOneWidget, reason: '应保留设置项：$title');
      }
      expect(find.text('设备管理'), findsNothing);
      expect(find.text('关于应用'), findsNothing);
      _expectNoMenuOrDrawer(tester);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}

void _expectNoMenuOrDrawer(WidgetTester tester) {
  expect(find.byIcon(Icons.menu_rounded), findsNothing);
  expect(find.byTooltip('菜单'), findsNothing);
  expect(find.byType(Drawer), findsNothing);

  final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
  expect(scaffold.drawer, isNull);
}
