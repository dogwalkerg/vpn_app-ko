import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/vpn/providers/vpn_controller.dart';
import 'package:vpn_app/features/vpn/usecases/connect_vpn_usecase.dart';
import 'package:vpn_app/features/vpn/usecases/disconnect_vpn_usecase.dart';
import 'package:vpn_app/features/vpn/usecases/is_connected_usecase.dart';

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
}

ProviderContainer _container({
  required Future<void> Function() connect,
  required Future<void> Function() disconnect,
  required Future<bool> Function() isConnected,
}) {
  return ProviderContainer(
    overrides: [
      vpnAccessProvider.overrideWithValue(true),
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
