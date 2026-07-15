import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/vpn/models/subscription_node.dart';
import 'package:vpn_app/features/vpn/platform/vpn_channel.dart';
import 'package:vpn_app/features/vpn/providers/subscription_nodes_provider.dart';
import 'package:vpn_app/features/vpn/providers/vpn_controller.dart';
import 'package:vpn_app/features/vpn/usecases/connect_vpn_usecase.dart';
import 'package:vpn_app/features/vpn/usecases/disconnect_vpn_usecase.dart';
import 'package:vpn_app/features/vpn/usecases/is_connected_usecase.dart';
import 'package:wireguard_flutter/wireguard_flutter.dart';

void main() {
  test(
    'forceDisconnect stops a core started by an in-flight connect',
    () async {
      final connectStarted = Completer<void>();
      final releaseConnect = Completer<void>();
      var coreRunning = false;
      var disconnectCalls = 0;
      final container = _container(
        connect: () async {
          connectStarted.complete();
          await releaseConnect.future;
          coreRunning = true;
        },
        disconnect: () async {
          disconnectCalls++;
          coreRunning = false;
        },
        isConnected: () async => coreRunning,
      );
      addTearDown(container.dispose);
      final controller = container.read(vpnControllerProvider.notifier);
      await _settleBootstrap();

      final connectAttempt = controller.connectPressed();
      await connectStarted.future;
      expect(controller.state, isA<VpnConnecting>());

      final disconnectAttempt = controller.forceDisconnect();
      await _waitUntil(() => disconnectCalls == 1);
      expect(controller.state, isA<VpnDisconnecting>());

      releaseConnect.complete();
      await Future.wait([connectAttempt, disconnectAttempt]);

      expect(disconnectCalls, 2);
      expect(coreRunning, isFalse);
      expect(controller.state, isA<VpnIdle>());
    },
  );

  test('normal connect and disconnect still use one stop operation', () async {
    var coreRunning = false;
    var connectCalls = 0;
    var disconnectCalls = 0;
    final container = _container(
      connect: () async {
        connectCalls++;
        coreRunning = true;
      },
      disconnect: () async {
        disconnectCalls++;
        coreRunning = false;
      },
      isConnected: () async => coreRunning,
    );
    addTearDown(container.dispose);
    final controller = container.read(vpnControllerProvider.notifier);
    await _settleBootstrap();

    await controller.connectPressed();
    expect(connectCalls, 1);
    expect(controller.state, isA<VpnConnected>());

    await controller.disconnectPressed();
    expect(disconnectCalls, 1);
    expect(coreRunning, isFalse);
    expect(controller.state, isA<VpnIdle>());
  });

  test('connected desktop health failure is shown as an error', () async {
    final container = _container(
      connect: () async {},
      disconnect: () async {},
      isConnected: () async => false,
    );
    addTearDown(container.dispose);
    final controller = container.read(vpnControllerProvider.notifier);
    await _settleBootstrap();
    await controller.connectPressed();
    expect(controller.state, isA<VpnConnected>());

    VpnChannel().report(
      VpnStatusEvent(stage: VpnStage.disconnected, reason: '系统代理被其他软件修改，请重新连接'),
    );
    await _waitUntil(() => controller.state is VpnError);

    expect((controller.state as VpnError).message, '系统代理被其他软件修改，请重新连接');
  });

  test(
    'the same desktop health failure is delivered after reconnect',
    () async {
      final container = _container(
        connect: () async {},
        disconnect: () async {},
        isConnected: () async => false,
      );
      addTearDown(container.dispose);
      final controller = container.read(vpnControllerProvider.notifier);
      await _settleBootstrap();

      const reason = 'system proxy changed';
      await controller.connectPressed();
      VpnChannel().report(
        VpnStatusEvent(stage: VpnStage.disconnected, reason: reason),
      );
      await _waitUntil(() => controller.state is VpnError);

      await controller.connectPressed();
      expect(controller.state, isA<VpnConnected>());
      VpnChannel().report(
        VpnStatusEvent(stage: VpnStage.disconnected, reason: reason),
      );
      await _waitUntil(
        () =>
            controller.state is VpnError &&
            (controller.state as VpnError).message == reason,
      );
    },
  );

  test('smart mode refreshes the fastest node before connecting', () async {
    final nodes = [_node('Node A', 443), _node('Node B', 8443)];
    var latencies = <String, int>{nodes[0].raw: 80, nodes[1].raw: 20};
    SubscriptionNode? nodeUsedByConnect;
    late ProviderContainer container;
    container = ProviderContainer(
      overrides: [
        vpnAccessProvider.overrideWithValue(true),
        prepareSubscriptionNodesForConnectionProvider.overrideWithValue(
          () async {},
        ),
        subscriptionNodesProvider.overrideWith((ref) async => nodes),
        selectedSubscriptionNodeProvider.overrideWith((ref) => nodes.first),
        nodeLatencyProbeProvider.overrideWithValue(
          (node) async => latencies[node.raw],
        ),
        connectVpnUseCaseProvider.overrideWithValue(() async {
          nodeUsedByConnect = container.read(selectedSubscriptionNodeProvider);
        }),
        disconnectVpnUseCaseProvider.overrideWithValue(() async {}),
        isVpnConnectedUseCaseProvider.overrideWithValue(() async => false),
      ],
    );
    addTearDown(container.dispose);
    await container.read(subscriptionNodesProvider.future);
    await container
        .read(nodeSelectionModeProvider.notifier)
        .selectSmart(nodes: nodes);
    expect(container.read(selectedSubscriptionNodeProvider)?.raw, nodes[1].raw);

    latencies = <String, int>{nodes[0].raw: 10, nodes[1].raw: 70};
    final controller = container.read(vpnControllerProvider.notifier);
    await _settleBootstrap();
    await controller.connectPressed();

    expect(nodeUsedByConnect?.raw, nodes[0].raw);
    expect(controller.state, isA<VpnConnected>());
    expect(container.read(nodeSelectionModeProvider), NodeSelectionMode.smart);
  });

  test('repeated disconnect taps share one stop operation', () async {
    final releaseDisconnect = Completer<void>();
    var coreRunning = true;
    var disconnectCalls = 0;
    final container = _container(
      connect: () async {},
      disconnect: () async {
        disconnectCalls++;
        await releaseDisconnect.future;
        coreRunning = false;
      },
      isConnected: () async => coreRunning,
    );
    addTearDown(container.dispose);
    final controller = container.read(vpnControllerProvider.notifier);
    await _settleBootstrap();
    expect(controller.state, isA<VpnConnected>());

    final attempts = List.generate(5, (_) => controller.forceDisconnect());
    await _waitUntil(() => disconnectCalls == 1);

    expect(controller.state, isA<VpnDisconnecting>());
    expect(disconnectCalls, 1);

    releaseDisconnect.complete();
    await Future.wait(attempts);

    expect(disconnectCalls, 1);
    expect(controller.state, isA<VpnIdle>());
  });

  test(
    'connection waits for a fresh account and subscription snapshot',
    () async {
      final refreshStarted = Completer<void>();
      final releaseRefresh = Completer<void>();
      var connectCalls = 0;
      final container = ProviderContainer(
        overrides: [
          vpnAccessProvider.overrideWithValue(true),
          prepareSubscriptionNodesForConnectionProvider.overrideWithValue(
            () async {
              refreshStarted.complete();
              await releaseRefresh.future;
            },
          ),
          connectVpnUseCaseProvider.overrideWithValue(
            () async => connectCalls++,
          ),
          disconnectVpnUseCaseProvider.overrideWithValue(() async {}),
          isVpnConnectedUseCaseProvider.overrideWithValue(() async => false),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(vpnControllerProvider.notifier);
      await _settleBootstrap();

      final attempt = controller.connectPressed();
      await refreshStarted.future;
      expect(controller.state, isA<VpnConnecting>());
      expect(connectCalls, 0);

      releaseRefresh.complete();
      await attempt;
      expect(connectCalls, 1);
      expect(controller.state, isA<VpnConnected>());
    },
  );

  test(
    'disconnect during connection preflight prevents the core from starting',
    () async {
      final refreshStarted = Completer<void>();
      final releaseRefresh = Completer<void>();
      var connectCalls = 0;
      var disconnectCalls = 0;
      final container = ProviderContainer(
        overrides: [
          vpnAccessProvider.overrideWithValue(true),
          prepareSubscriptionNodesForConnectionProvider.overrideWithValue(
            () async {
              refreshStarted.complete();
              await releaseRefresh.future;
            },
          ),
          connectVpnUseCaseProvider.overrideWithValue(
            () async => connectCalls++,
          ),
          disconnectVpnUseCaseProvider.overrideWithValue(
            () async => disconnectCalls++,
          ),
          isVpnConnectedUseCaseProvider.overrideWithValue(() async => false),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(vpnControllerProvider.notifier);
      await _settleBootstrap();

      final connectAttempt = controller.connectPressed();
      await refreshStarted.future;
      final disconnectAttempt = controller.forceDisconnect();
      await disconnectAttempt;
      releaseRefresh.complete();
      await connectAttempt;

      expect(connectCalls, 0);
      expect(disconnectCalls, 1);
      expect(controller.state, isA<VpnIdle>());
    },
  );
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

ProviderContainer _container({
  required Future<void> Function() connect,
  required Future<void> Function() disconnect,
  required Future<bool> Function() isConnected,
}) {
  return ProviderContainer(
    overrides: [
      vpnAccessProvider.overrideWithValue(true),
      prepareSubscriptionNodesForConnectionProvider.overrideWithValue(
        () async {},
      ),
      connectVpnUseCaseProvider.overrideWithValue(connect),
      disconnectVpnUseCaseProvider.overrideWithValue(disconnect),
      isVpnConnectedUseCaseProvider.overrideWithValue(isConnected),
    ],
  );
}

Future<void> _settleBootstrap() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for controller operation');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
