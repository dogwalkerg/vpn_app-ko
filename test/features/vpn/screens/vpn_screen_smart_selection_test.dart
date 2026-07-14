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
  final nodes = [_node('Node A', 443), _node('Node B', 8443)];

  testWidgets('smart selection is checked and picks the fastest node', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final dio = Dio();
    addTearDown(() => dio.close(force: true));
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(ApiService(dio)),
        currentUsernameProvider.overrideWithValue('test-user'),
        connectVpnUseCaseProvider.overrideWithValue(() async {}),
        disconnectVpnUseCaseProvider.overrideWithValue(() async {}),
        isVpnConnectedUseCaseProvider.overrideWithValue(() async => false),
        subscriptionNodesProvider.overrideWith((ref) async => nodes),
        selectedSubscriptionNodeProvider.overrideWith((ref) => nodes.first),
        nodeLatencyProbeProvider.overrideWithValue(
          (node) async => node.raw == nodes[0].raw ? 80 : 20,
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: appLightTheme, home: const VpnScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('线路'));
    await tester.pump();
    await tester.tap(find.text('智能选择'));
    await tester.pumpAndSettle();

    expect(container.read(nodeSelectionModeProvider), NodeSelectionMode.smart);
    expect(container.read(selectedSubscriptionNodeProvider)?.raw, nodes[1].raw);

    await tester.tap(find.byTooltip('线路'));
    await tester.pump();
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    final smartCard = find.ancestor(
      of: find.text('智能选择'),
      matching: find.byType(InkWell),
    );
    expect(
      find.descendant(
        of: smartCard,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Node A'));
    await tester.pumpAndSettle();
    expect(container.read(nodeSelectionModeProvider), NodeSelectionMode.manual);
    expect(container.read(selectedSubscriptionNodeProvider)?.raw, nodes[0].raw);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

SubscriptionNode _node(String name, int port) => SubscriptionNode(
  name: name,
  type: 'VLESS',
  host: '127.0.0.1',
  port: port,
  country: 'Test',
  flag: '',
  speedMbps: 0,
  load: 0,
  raw: 'vless://test@127.0.0.1:$port#$name',
);
