import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vpn_app/features/subscription/models/subscription_state.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/vpn/models/subscription_node.dart';
import 'package:vpn_app/features/vpn/providers/subscription_nodes_provider.dart';
import 'package:vpn_app/features/vpn/providers/vpn_providers.dart';
import 'package:vpn_app/ui/widgets/app_custom_appbar.dart';
import 'package:vpn_app/ui/widgets/app_drawer.dart';
import 'package:vpn_app/ui/widgets/themed_scaffold.dart';

class VpnScreen extends ConsumerStatefulWidget {
  const VpnScreen({super.key});

  @override
  ConsumerState<VpnScreen> createState() => _VpnScreenState();
}

class _VpnScreenState extends ConsumerState<VpnScreen> {
  Timer? _timer;
  DateTime? _connectedAt;
  Duration _connectedFor = Duration.zero;
  WebSocket? _trafficSocket;
  int _downloadSpeed = 0;
  int _uploadSpeed = 0;

  @override
  void dispose() {
    _timer?.cancel();
    _trafficSocket?.close();
    super.dispose();
  }

  void _syncTimer(bool connected) {
    if (connected && _connectedAt == null) {
      _connectedAt = DateTime.now();
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _connectedAt != null) {
          setState(
            () => _connectedFor = DateTime.now().difference(_connectedAt!),
          );
        }
      });
      _listenToTraffic();
    } else if (!connected && _connectedAt != null) {
      _timer?.cancel();
      _timer = null;
      _connectedAt = null;
      _connectedFor = Duration.zero;
      _downloadSpeed = 0;
      _uploadSpeed = 0;
      _trafficSocket?.close();
      _trafficSocket = null;
    }
  }

  Future<void> _listenToTraffic() async {
    if (!Platform.isWindows && !Platform.isMacOS) return;
    try {
      final socket = await WebSocket.connect('ws://127.0.0.1:9090/traffic');
      _trafficSocket = socket;
      socket.listen(
        (event) {
          final data = jsonDecode(event.toString());
          if (mounted && data is Map<String, dynamic>) {
            setState(() {
              _downloadSpeed = (data['down'] as num? ?? 0).toInt();
              _uploadSpeed = (data['up'] as num? ?? 0).toInt();
            });
          }
        },
        onDone: () => _trafficSocket = null,
        onError: (_) => _trafficSocket = null,
      );
    } catch (_) {
      _trafficSocket = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final vpnState = ref.watch(vpnControllerProvider);
    final nodes = ref.watch(subscriptionNodesProvider);
    final selected = ref.watch(selectedSubscriptionNodeProvider);
    final subscription = ref.watch(subscriptionControllerProvider);
    final allowed = ref.watch(vpnAccessProvider);
    final connected = vpnState is VpnConnected;
    final busy = vpnState is VpnConnecting || vpnState is VpnDisconnecting;
    final error = vpnState is VpnError ? vpnState.message : null;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncTimer(connected));

    return ThemedScaffold(
      appBar: AppCustomAppBar(
        title: '自由云',
        leading: Builder(
          builder: (context) => IconButton(
            tooltip: '菜单',
            icon: const Icon(Icons.menu_rounded),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      drawer: const AppDrawer(),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Column(
                  children: [
                    _CurrentNodeCard(
                      node: selected,
                      loading: nodes.isLoading,
                      onTap: () =>
                          nodes.whenData((items) => _openNodePicker(context)),
                      onRefresh: () =>
                          ref.invalidate(subscriptionNodesProvider),
                    ),
                    const SizedBox(height: 34),
                    _PowerButton(
                      connected: connected,
                      busy: busy,
                      enabled: allowed && selected != null,
                      onPressed: () async {
                        final controller = ref.read(
                          vpnControllerProvider.notifier,
                        );
                        connected
                            ? await controller.disconnectPressed()
                            : await controller.connectPressed();
                      },
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      '连接时长',
                      style: TextStyle(color: Color(0xFF8B909A), fontSize: 16),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _durationText(_connectedFor),
                      style: const TextStyle(
                        fontSize: 38,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _TrafficSummary(subscription: subscription),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _SpeedCard(
                            icon: Icons.arrow_downward_rounded,
                            label: '下载',
                            color: const Color(0xFF5966D9),
                            bytesPerSecond: _downloadSpeed,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _SpeedCard(
                            icon: Icons.arrow_upward_rounded,
                            label: '上传',
                            color: const Color(0xFF29B765),
                            bytesPerSecond: _uploadSpeed,
                          ),
                        ),
                      ],
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        error,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFFD14343),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openNodePicker(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFFF4F5F9),
      builder: (_) =>
          FractionallySizedBox(heightFactor: .94, child: const _NodePicker()),
    );
  }
}

class _CurrentNodeCard extends StatelessWidget {
  const _CurrentNodeCard({
    required this.node,
    required this.loading,
    required this.onTap,
    required this.onRefresh,
  });
  final SubscriptionNode? node;
  final bool loading;
  final VoidCallback onTap;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    elevation: 2,
    shadowColor: Colors.black26,
    borderRadius: BorderRadius.circular(8),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: Color(0xFFF0F2F7),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.public_rounded,
                color: Color(0xFF168FD5),
                size: 27,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node?.name ?? (loading ? '正在获取线路' : '智能选择'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF15171A),
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    node == null ? '选择可用线路' : '${node!.host}:${node!.port}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF747A84),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '刷新订阅',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFF7A8089)),
          ],
        ),
      ),
    ),
  );
}

class _PowerButton extends StatelessWidget {
  const _PowerButton({
    required this.connected,
    required this.busy,
    required this.enabled,
    required this.onPressed,
  });
  final bool connected;
  final bool busy;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 280,
    height: 280,
    child: DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFE9EDF7),
        border: Border.all(color: const Color(0xFFDDE3F0), width: 16),
      ),
      child: Center(
        child: Container(
          width: 190,
          height: 190,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: connected
                ? const Color(0xFF252A67)
                : const Color(0xFF17191D),
            boxShadow: [
              BoxShadow(
                color: (connected ? const Color(0xFF4654C7) : Colors.black)
                    .withValues(alpha: .28),
                blurRadius: 28,
                spreadRadius: 8,
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled && !busy ? onPressed : null,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (busy)
                    const SizedBox(
                      width: 38,
                      height: 38,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: Colors.white,
                      ),
                    )
                  else
                    const Icon(
                      Icons.power_settings_new_rounded,
                      size: 52,
                      color: Colors.white70,
                    ),
                  const SizedBox(height: 12),
                  Text(
                    busy
                        ? '正在连接'
                        : connected
                        ? '已连接'
                        : '点击加速',
                    style: TextStyle(
                      color: connected ? const Color(0xFF58F0C0) : Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _TrafficSummary extends StatelessWidget {
  const _TrafficSummary({required this.subscription});
  final SubscriptionState subscription;
  @override
  Widget build(BuildContext context) {
    var total = '--';
    var used = '--';
    var remaining = '--';
    if (subscription is SubscriptionReady) {
      final status = (subscription as SubscriptionReady).status;
      total = _bytes(status.trafficTotal);
      used = _bytes(status.trafficUsed);
      remaining = _bytes(
        (status.trafficTotal - status.trafficUsed).clamp(
          0,
          status.trafficTotal,
        ).toInt(),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E4EA)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _TrafficValue(label: '总流量', value: total),
          ),
          const SizedBox(height: 38, child: VerticalDivider()),
          Expanded(
            child: _TrafficValue(label: '已消耗', value: used),
          ),
          const SizedBox(height: 38, child: VerticalDivider()),
          Expanded(
            child: _TrafficValue(label: '剩余', value: remaining),
          ),
        ],
      ),
    );
  }
}

class _TrafficValue extends StatelessWidget {
  const _TrafficValue({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        label,
        style: const TextStyle(color: Color(0xFF858A93), fontSize: 12),
      ),
      const SizedBox(height: 5),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xFF25272C),
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}

class _SpeedCard extends StatelessWidget {
  const _SpeedCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.bytesPerSecond,
  });
  final IconData icon;
  final String label;
  final Color color;
  final int bytesPerSecond;
  @override
  Widget build(BuildContext context) => Container(
    height: 94,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFE2E4EA)),
    ),
    child: Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: Color(0xFF7B8089))),
              Text(
                '${_bytes(bytesPerSecond)}/s',
                maxLines: 1,
                style: const TextStyle(
                  color: Color(0xFF202226),
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _NodePicker extends ConsumerWidget {
  const _NodePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedSubscriptionNodeProvider);
    final nodesState = ref.watch(subscriptionNodesProvider);
    final nodes = nodesState.valueOrNull ?? const <SubscriptionNode>[];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 10, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '选择线路',
                  style: TextStyle(
                    color: Color(0xFF191B20),
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新订阅',
                onPressed: nodesState.isLoading
                    ? null
                    : () => ref.invalidate(subscriptionNodesProvider),
                icon: nodesState.isLoading
                    ? const SizedBox(
                        width: 25,
                        height: 25,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Icon(Icons.refresh_rounded, size: 31),
              ),
            ],
          ),
        ),
        Expanded(
          child: nodesState.hasError
              ? Center(
                  child: TextButton.icon(
                    onPressed: () => ref.invalidate(subscriptionNodesProvider),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('订阅刷新失败，点击重试'),
                  ),
                )
              : nodes.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                  itemCount: nodes.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0)
                      return _SmartNodeTile(
                        onTap: () => _select(context, ref, nodes.first),
                      );
                    final node = nodes[index - 1];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 11),
                      child: _NodeTile(
                        node: node,
                        selected: selected?.raw == node.raw,
                        onTap: () => _select(context, ref, node),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _select(
    BuildContext context,
    WidgetRef ref,
    SubscriptionNode node,
  ) async {
    final state = ref.read(vpnControllerProvider);
    if (state is VpnConnected || state is VpnConnecting)
      await ref.read(vpnControllerProvider.notifier).disconnectPressed();
    ref.read(selectedSubscriptionNodeProvider.notifier).state = node;
    if (context.mounted) Navigator.of(context).pop();
  }
}

class _SmartNodeTile extends StatelessWidget {
  const _SmartNodeTile({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: _NodeCard(
      icon: Icons.auto_awesome_rounded,
      title: '智能选择',
      subtitle: '自动选择首个订阅线路',
      selected: false,
      onTap: onTap,
    ),
  );
}

class _NodeTile extends StatefulWidget {
  const _NodeTile({
    required this.node,
    required this.selected,
    required this.onTap,
  });
  final SubscriptionNode node;
  final bool selected;
  final VoidCallback onTap;
  @override
  State<_NodeTile> createState() => _NodeTileState();
}

class _NodeTileState extends State<_NodeTile> {
  late Future<int?> latency = measureNodeLatency(widget.node);
  @override
  Widget build(BuildContext context) => FutureBuilder<int?>(
    future: latency,
    builder: (_, snapshot) {
      final value = snapshot.connectionState == ConnectionState.waiting
          ? '测速中'
          : snapshot.data == null
          ? '连接超时'
          : '${snapshot.data} ms';
      return _NodeCard(
        icon: Icons.public_rounded,
        title: widget.node.name,
        subtitle: '线路质量：$value',
        selected: widget.selected,
        onTap: widget.onTap,
      );
    },
  );
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    elevation: 1,
    shadowColor: Colors.black12,
    borderRadius: BorderRadius.circular(8),
    child: InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: const BoxDecoration(
                color: Color(0xFFF0F2F7),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: const Color(0xFF168FD5), size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF17191D),
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFFE5A514),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 32,
              color: selected
                  ? const Color(0xFF202226)
                  : const Color(0xFFD2D5DA),
            ),
          ],
        ),
      ),
    ),
  );
}

String _durationText(Duration value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.inHours)} : ${two(value.inMinutes.remainder(60))} : ${two(value.inSeconds.remainder(60))}';
}

String _bytes(int value) {
  if (value <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var amount = value.toDouble();
  var unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit++;
  }
  return '${amount.toStringAsFixed(unit < 2 ? 0 : 2)} ${units[unit]}';
}
