// lib/features/vpn/providers/vpn_controller.dart
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vpn_app/core/errors/ui_error.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/vpn/platform/vpn_channel.dart';
import 'package:vpn_app/features/vpn/providers/subscription_nodes_provider.dart';
import 'package:wireguard_flutter/wireguard_flutter.dart';
import '../usecases/connect_vpn_usecase.dart';
import '../usecases/disconnect_vpn_usecase.dart';
import '../usecases/is_connected_usecase.dart';

sealed class VpnState {
  const VpnState();
}

class VpnIdle extends VpnState {
  const VpnIdle();
}

class VpnConnecting extends VpnState {
  const VpnConnecting();
}

class VpnConnected extends VpnState {
  const VpnConnected();
}

class VpnDisconnecting extends VpnState {
  const VpnDisconnecting();
}

class VpnError extends VpnState {
  final String message;
  const VpnError(this.message);
}

final vpnControllerProvider = StateNotifierProvider<VpnController, VpnState>((
  ref,
) {
  final ctrl = VpnController(
    connect: ref.watch(connectVpnUseCaseProvider),
    disconnect: ref.watch(disconnectVpnUseCaseProvider),
    isConnected: ref.watch(isVpnConnectedUseCaseProvider),
    ref: ref,
  );
  return ctrl;
}, name: 'vpnController');

class VpnController extends StateNotifier<VpnState> {
  VpnController({
    required this.connect,
    required this.disconnect,
    required this.isConnected,
    required this.ref,
  }) : super(const VpnIdle()) {
    unawaited(bootstrap());

    ref.listen<bool>(vpnAccessProvider, (prev, next) async {
      if (prev == true &&
          next == false &&
          (state is VpnConnected || state is VpnConnecting)) {
        await forceDisconnect();
      }
    });

    _vpnSub = VpnChannel().onStatus.listen(_onVpnStatus);

    ref.onDispose(() => _vpnSub?.cancel());
    ref.onDispose(() => _connectTimeout?.cancel());
  }

  final ConnectVpn connect;
  final DisconnectVpn disconnect;
  final IsVpnConnected isConnected;
  final Ref ref;
  StreamSubscription<VpnStatusEvent>? _vpnSub;
  Timer? _connectTimeout;
  Future<void>? _connectFuture;
  Future<void>? _disconnectFuture;
  int _operationGeneration = 0;

  Future<void> bootstrap() async {
    final generation = _operationGeneration;
    try {
      final c = await isConnected();
      if (generation != _operationGeneration ||
          _connectFuture != null ||
          _disconnectFuture != null) {
        return;
      }
      state = c ? const VpnConnected() : const VpnIdle();
    } catch (_) {}
  }

  bool get _canUseVpn => ref.read(vpnAccessProvider);

  void _onVpnStatus(VpnStatusEvent e) async {
    if (state is VpnDisconnecting) return;

    if (!_canUseVpn && e.stage == VpnStage.connected) {
      unawaited(disconnect());
      return;
    }

    switch (e.stage) {
      case VpnStage.connected:
        _connectTimeout?.cancel();
        if (state is! VpnConnected && state is! VpnDisconnecting) {
          state = const VpnConnected();
        }
        break;
      case VpnStage.disconnected:
        final reason = e.reason?.trim();
        if (state is VpnConnected && reason != null && reason.isNotEmpty) {
          state = VpnError(reason);
        } else if (state is VpnDisconnecting) {
          state = const VpnIdle();
        } else if (state is VpnConnecting) {
        } else if (state is! VpnIdle) {
          state = const VpnIdle();
        }
        break;
      case VpnStage.connecting:
        if (state is! VpnConnecting) {
          state = const VpnConnecting();
        }
        break;
      default:
        if (state is VpnConnecting) {
        } else if (state is! VpnIdle) {
          state = const VpnIdle();
        }
    }
  }

  Future<void> connectPressed() async {
    if (_connectFuture != null ||
        _disconnectFuture != null ||
        state is VpnConnecting ||
        state is VpnDisconnecting) {
      return;
    }
    final generation = ++_operationGeneration;
    state = const VpnConnecting();
    try {
      await ref.read(prepareSubscriptionNodesForConnectionProvider)();
    } catch (e) {
      if (!mounted || generation != _operationGeneration) return;
      state = VpnError(presentableError(e));
      return;
    }
    if (!mounted || generation != _operationGeneration) return;
    if (!_canUseVpn) {
      state = const VpnError('订阅未激活，请先开通套餐');
      return;
    }
    _connectTimeout?.cancel();
    _connectTimeout = Timer(const Duration(seconds: 90), () {
      if (mounted && state is VpnConnecting) {
        state = const VpnError('连接超时，请检查节点或网络');
      }
    });
    if (ref.read(nodeSelectionModeProvider) == NodeSelectionMode.smart) {
      final selected = await ref
          .read(nodeSelectionModeProvider.notifier)
          .refreshSmartSelection();
      if (!mounted || generation != _operationGeneration) return;
      if (selected == null) {
        _connectTimeout?.cancel();
        state = const VpnError('没有可用节点，请刷新订阅后重试');
        return;
      }
    }
    final future = Future<void>.sync(connect);
    _connectFuture = future;
    try {
      await future;
      if (generation != _operationGeneration) return;
      _connectTimeout?.cancel();
      if (!_canUseVpn) {
        await forceDisconnect();
        state = const VpnError('当前账号已不能使用代理，请刷新账号状态');
        return;
      }
      if (state is VpnConnecting) state = const VpnConnected();
    } catch (e) {
      if (generation != _operationGeneration) return;
      _connectTimeout?.cancel();
      state = VpnError(presentableError(e));
    } finally {
      if (identical(_connectFuture, future)) _connectFuture = null;
    }
  }

  Future<void> disconnectPressed() async {
    await forceDisconnect();
  }

  Future<void> forceDisconnect() {
    _operationGeneration++;
    _connectTimeout?.cancel();
    final active = _disconnectFuture;
    if (active != null) return active;
    final future = _performDisconnect(_connectFuture);
    _disconnectFuture = future;
    return future.whenComplete(() {
      if (identical(_disconnectFuture, future)) _disconnectFuture = null;
    });
  }

  Future<void> _performDisconnect(Future<void>? inFlightConnect) async {
    state = const VpnDisconnecting();
    try {
      if (inFlightConnect == null) {
        await disconnect();
      } else {
        // The first stop handles resources already created by connect. The
        // second handles a core that starts after that stop has completed.
        try {
          await disconnect();
        } catch (_) {}
        try {
          await inFlightConnect;
        } catch (_) {}
        await disconnect();
      }
      if (await isConnected()) {
        throw StateError('代理核心未能完全停止');
      }
      state = const VpnIdle();
    } catch (e) {
      state = VpnError(presentableError(e));
      rethrow;
    }
  }
}
