import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vpn_app/core/api/coco_api.dart';
import 'package:vpn_app/core/router/routes.dart';
import 'package:vpn_app/features/auth/providers/auth_providers.dart';
import 'package:vpn_app/features/subscription/models/subscription_state.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/traffic/providers/traffic_accounting_provider.dart';
import 'package:vpn_app/features/vpn/models/subscription_node.dart';
import 'package:vpn_app/features/vpn/providers/subscription_nodes_provider.dart';
import 'package:vpn_app/features/vpn/providers/vpn_providers.dart';
import 'package:vpn_app/features/vpn/usecases/disconnect_with_traffic.dart';
import 'package:vpn_app/ui/widgets/app_custom_appbar.dart';
import 'package:vpn_app/ui/widgets/themed_scaffold.dart';
import 'package:vpn_app/ui/widgets/app_snackbar.dart';

const _lineQualityLabel = '线路质量：★★★★★';

class VpnScreen extends ConsumerStatefulWidget {
  const VpnScreen({super.key});

  @override
  ConsumerState<VpnScreen> createState() => _VpnScreenState();
}

class _VpnScreenState extends ConsumerState<VpnScreen> {
  Timer? _timer;
  Timer? _subscriptionRefreshTimer;
  int _tabIndex = 0;
  DateTime? _connectedAt;
  Duration _connectedFor = Duration.zero;

  @override
  void initState() {
    super.initState();
    _subscriptionRefreshTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshNodes(showFeedback: false),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _subscriptionRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshNodes({bool showFeedback = true}) async {
    try {
      await refreshSubscriptionNodes(ref);
      if (!mounted || !showFeedback) return;
      final nodes = ref.read(subscriptionNodesProvider).valueOrNull ?? const [];
      showAppSnackbar(
        context,
        text: nodes.isEmpty ? '订阅未返回可用节点' : '订阅节点已更新',
        type: nodes.isEmpty ? AppSnackbarType.error : AppSnackbarType.success,
      );
    } catch (error) {
      if (!mounted || !showFeedback) return;
      showAppSnackbar(
        context,
        text: '订阅刷新失败：${error.toString()}',
        type: AppSnackbarType.error,
      );
    }
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
    } else if (!connected && _connectedAt != null) {
      _timer?.cancel();
      _timer = null;
      _connectedAt = null;
      _connectedFor = Duration.zero;
    }
  }

  @override
  Widget build(BuildContext context) {
    final vpnState = ref.watch(vpnControllerProvider);
    final nodes = ref.watch(subscriptionNodesProvider);
    final nodesRefreshing = ref.watch(subscriptionNodesRefreshingProvider);
    final selected = ref.watch(selectedSubscriptionNodeProvider);
    final subscription = ref.watch(subscriptionControllerProvider);
    final traffic = ref.watch(trafficAccountingProvider);
    final allowed = ref.watch(vpnAccessProvider);
    final connected = vpnState is VpnConnected;
    final disconnecting = vpnState is VpnDisconnecting;
    final busy = vpnState is VpnConnecting || vpnState is VpnDisconnecting;
    final error = vpnState is VpnError ? vpnState.message : traffic.notice;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncTimer(connected));

    return ThemedScaffold(
      overlayColor: const Color(0xFFF2F4F7),
      appBar: const AppCustomAppBar(title: '自由云'),
      bottomNavigationBar: _BottomNavigation(
        selectedIndex: _tabIndex,
        onHome: () => setState(() => _tabIndex = 0),
        onNodes: () => setState(() => _tabIndex = 1),
        onSettings: () => setState(() => _tabIndex = 2),
      ),
      body: IndexedStack(
        index: _tabIndex,
        children: [
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: Column(
                      children: [
                        _CurrentNodeCard(
                          node: selected,
                          loading: nodes.isLoading || nodesRefreshing,
                          onTap: () => setState(() => _tabIndex = 1),
                          onRefresh: _refreshNodes,
                        ),
                        const SizedBox(height: 6),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, _) {
                              const diameter = 160.0;
                              return Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _PowerButton(
                                    diameter: diameter,
                                    connected: connected,
                                    busy: busy,
                                    disconnecting: disconnecting,
                                    enabled: allowed && selected != null,
                                    onPressed: () async {
                                      final controller = ref.read(
                                        vpnControllerProvider.notifier,
                                      );
                                      if (connected) {
                                        final accounting = ref.read(
                                          trafficAccountingProvider.notifier,
                                        );
                                        await disconnectWithTrafficSync(
                                          flushTraffic: accounting.flush,
                                          disconnectVpn:
                                              controller.disconnectPressed,
                                        );
                                      } else {
                                        await controller.connectPressed();
                                      }
                                    },
                                  ),
                                  if (error != null) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      error,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Color(0xFFD14343),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ],
                              );
                            },
                          ),
                        ),
                        const Text(
                          '连接时长',
                          style: TextStyle(
                            color: Color(0xFF8B909A),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _durationText(_connectedFor),
                          style: const TextStyle(
                            fontSize: 38,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _TrafficSummary(
                          subscription: subscription,
                          pendingBytes: traffic.pendingBytes,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: _SpeedCard(
                                icon: Icons.arrow_downward_rounded,
                                label: '下载',
                                color: const Color(0xFF5966D9),
                                bytesPerSecond: traffic.downloadBytesPerSecond,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _SpeedCard(
                                icon: Icons.arrow_upward_rounded,
                                label: '上传',
                                color: const Color(0xFF29B765),
                                bytesPerSecond: traffic.uploadBytesPerSecond,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: _NodePicker(onSelected: () => setState(() => _tabIndex = 0)),
          ),
          const SafeArea(child: _SettingsPanel()),
        ],
      ),
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
  Widget build(BuildContext context) => SizedBox(
    height: 64,
    child: Material(
      color: Colors.white,
      elevation: 2,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
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
                      node == null
                          ? (loading ? '正在获取线路' : '智能选择')
                          : _nodeDisplayName(node!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF15171A),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      node == null ? '选择可用线路' : _lineQualityLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: node == null
                            ? const Color(0xFF747A84)
                            : const Color(0xFFE5A514),
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
    ),
  );
}

class _PowerButton extends StatelessWidget {
  const _PowerButton({
    required this.diameter,
    required this.connected,
    required this.busy,
    required this.disconnecting,
    required this.enabled,
    required this.onPressed,
  });
  final double diameter;
  final bool connected;
  final bool busy;
  final bool disconnecting;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: diameter,
    height: diameter,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: diameter,
          height: diameter,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFFE9EDF7),
          ),
        ),
        Container(
          width: diameter * (144 / 160),
          height: diameter * (144 / 160),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFFE1E7F3),
          ),
        ),
        Container(
          width: diameter * (104 / 160),
          height: diameter * (104 / 160),
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
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: Colors.white,
                      ),
                    )
                  else
                    const Icon(
                      Icons.power_settings_new_rounded,
                      size: 36,
                      color: Colors.white70,
                    ),
                  const SizedBox(height: 4),
                  Text(
                    busy
                        ? (disconnecting ? '正在断开' : '正在连接')
                        : connected
                        ? '已连接'
                        : '点击加速',
                    style: TextStyle(
                      color: connected ? const Color(0xFF58F0C0) : Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _TrafficSummary extends StatelessWidget {
  const _TrafficSummary({
    required this.subscription,
    required this.pendingBytes,
  });
  final SubscriptionState subscription;
  final int pendingBytes;
  @override
  Widget build(BuildContext context) {
    var total = '--';
    var used = '--';
    var remaining = '--';
    if (subscription is SubscriptionReady) {
      final status = (subscription as SubscriptionReady).status;
      total = _bytes(status.trafficTotal);
      final displayedUsed = (status.trafficUsed + pendingBytes)
          .clamp(0, status.trafficTotal)
          .toInt();
      used = _bytes(displayedUsed);
      remaining = _bytes(
        (status.trafficTotal - displayedUsed)
            .clamp(0, status.trafficTotal)
            .toInt(),
      );
    }
    return Container(
      width: double.infinity,
      height: 58,
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 10),
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
    height: 60,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFE2E4EA)),
    ),
    child: Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF7B8089),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                _rate(bytesPerSecond),
                maxLines: 1,
                style: const TextStyle(
                  color: Color(0xFF202226),
                  fontSize: 13,
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
  const _NodePicker({required this.onSelected});

  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedSubscriptionNodeProvider);
    final nodesState = ref.watch(subscriptionNodesProvider);
    final refreshing = ref.watch(subscriptionNodesRefreshingProvider);
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
                onPressed: nodesState.isLoading || refreshing
                    ? null
                    : () => _refresh(context, ref),
                icon: nodesState.isLoading || refreshing
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
                    onPressed: () => _refresh(context, ref),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('订阅刷新失败，点击重试'),
                  ),
                )
              : nodes.isEmpty
              ? Center(
                  child: TextButton.icon(
                    onPressed: refreshing ? null : () => _refresh(context, ref),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('订阅未返回可用节点，点击刷新重试'),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                  itemCount: nodes.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _SmartNodeTile(
                        onTap: () => _select(context, ref, nodes.first),
                      );
                    }
                    final node = nodes[index - 1];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 11),
                      child: _NodeTile(
                        node: node,
                        selected: selected?.raw == node.raw,
                        latencyProbe: ref.read(nodeLatencyProbeProvider),
                        onTap: () => _select(context, ref, node),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    try {
      await refreshSubscriptionNodes(ref);
      if (!context.mounted) return;
      final nodes = ref.read(subscriptionNodesProvider).valueOrNull ?? const [];
      showAppSnackbar(
        context,
        text: nodes.isEmpty ? '订阅未返回可用节点' : '订阅节点已更新',
        type: nodes.isEmpty ? AppSnackbarType.error : AppSnackbarType.success,
      );
    } catch (error) {
      if (!context.mounted) return;
      showAppSnackbar(
        context,
        text: '订阅刷新失败：${error.toString()}',
        type: AppSnackbarType.error,
      );
    }
  }

  Future<void> _select(
    BuildContext context,
    WidgetRef ref,
    SubscriptionNode node,
  ) async {
    final state = ref.read(vpnControllerProvider);
    if (state is VpnConnected || state is VpnConnecting) {
      await ref.read(vpnControllerProvider.notifier).disconnectPressed();
    }
    ref.read(selectedSubscriptionNodeProvider.notifier).state = node;
    if (context.mounted) onSelected();
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
      subtitle: _lineQualityLabel,
      selected: false,
      onTap: onTap,
    ),
  );
}

class _NodeTile extends StatefulWidget {
  const _NodeTile({
    required this.node,
    required this.selected,
    required this.latencyProbe,
    required this.onTap,
  });
  final SubscriptionNode node;
  final bool selected;
  final NodeLatencyProbe latencyProbe;
  final VoidCallback onTap;

  @override
  State<_NodeTile> createState() => _NodeTileState();
}

class _NodeTileState extends State<_NodeTile> {
  late Future<int?> latency;

  @override
  void initState() {
    super.initState();
    latency = widget.latencyProbe(widget.node);
  }

  @override
  void didUpdateWidget(covariant _NodeTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.raw != widget.node.raw ||
        oldWidget.latencyProbe != widget.latencyProbe) {
      latency = widget.latencyProbe(widget.node);
    }
  }

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
        title: _nodeDisplayName(widget.node),
        subtitle: _lineQualityLabel,
        detail: '接入延迟：$value',
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
    this.detail,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final String? detail;
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
                  Wrap(
                    spacing: 10,
                    runSpacing: 2,
                    children: [
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Color(0xFFE5A514),
                          fontSize: 13,
                        ),
                      ),
                      if (detail != null)
                        Text(
                          detail!,
                          style: const TextStyle(
                            color: Color(0xFFE5A514),
                            fontSize: 13,
                          ),
                        ),
                    ],
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

class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation({
    required this.selectedIndex,
    required this.onHome,
    required this.onNodes,
    required this.onSettings,
  });
  final int selectedIndex;
  final VoidCallback onHome;
  final VoidCallback onNodes;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      height: 64,
      decoration: const BoxDecoration(
        color: Color(0xFFF7F7F8),
        border: Border(top: BorderSide(color: Color(0xFFE2E3E7))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _NavButton(
            icon: Icons.home_rounded,
            label: '主页',
            selected: selectedIndex == 0,
            onTap: onHome,
          ),
          _NavButton(
            icon: Icons.hub_rounded,
            label: '线路',
            selected: selectedIndex == 1,
            onTap: onNodes,
          ),
          _NavButton(
            icon: Icons.settings_rounded,
            label: '设置',
            selected: selectedIndex == 2,
            onTap: onSettings,
          ),
        ],
      ),
    ),
  );
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    onPressed: onTap,
    icon: Icon(
      icon,
      size: 24,
      color: selected ? const Color(0xFF2D235E) : const Color(0xFF777A80),
    ),
  );
}

class _SettingsPanel extends ConsumerWidget {
  const _SettingsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final username = ref.watch(currentUsernameProvider) ?? '用户';
    final subscription = ref.watch(subscriptionControllerProvider);
    final status = subscription is SubscriptionReady
        ? subscription.status
        : null;
    final subscriptionLabel = _settingsSubscriptionLabel(subscription);
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Text(
            '设置',
            style: TextStyle(
              color: Color(0xFF17191D),
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF30235E),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 28,
                      backgroundColor: Colors.white,
                      child: Icon(
                        Icons.cloud_rounded,
                        color: Color(0xFFE7A622),
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            username,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            subscriptionLabel,
                            style: const TextStyle(color: Color(0xFFFFCC42)),
                          ),
                          Text(
                            '余额：${status?.balance.toStringAsFixed(2) ?? '--'} 自由币',
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _SettingsItem(
                icon: Icons.diamond_rounded,
                title: '会员中心与续费',
                onTap: () {
                  context.pushNamed(AppRoute.subscription.name);
                },
              ),
              _SettingsItem(
                icon: Icons.event_available_rounded,
                title: '每日签到',
                onTap: () async {
                  try {
                    final before = await ref.read(cocoApiProvider).userInfo();
                    final after = await ref.read(cocoApiProvider).checkin();
                    await ref
                        .read(subscriptionControllerProvider.notifier)
                        .fetch();
                    final reward =
                        (after.trafficTotal - before.trafficTotal) /
                        (1024 * 1024);
                    if (context.mounted) {
                      showAppSnackbar(
                        context,
                        text: '签到成功，获得 ${reward.toStringAsFixed(0)} MB 流量',
                        type: AppSnackbarType.success,
                      );
                    }
                  } catch (error) {
                    if (context.mounted) {
                      showAppSnackbar(
                        context,
                        text: error.toString(),
                        type: AppSnackbarType.error,
                      );
                    }
                  }
                },
              ),
              _SettingsItem(
                icon: Icons.campaign_outlined,
                title: '公告',
                onTap: () async {
                  try {
                    final rows = await ref
                        .read(cocoApiProvider)
                        .announcements();
                    if (!context.mounted) return;
                    await showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('公告'),
                        content: SingleChildScrollView(
                          child: Text(
                            rows.isEmpty
                                ? '暂无公告'
                                : rows
                                      .map((item) => item.markdown)
                                      .join('\n\n'),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    );
                  } catch (error) {
                    if (context.mounted) {
                      showAppSnackbar(
                        context,
                        text: error.toString(),
                        type: AppSnackbarType.error,
                      );
                    }
                  }
                },
              ),
              _SettingsItem(
                icon: Icons.help_outline_rounded,
                title: '帮助',
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('使用帮助'),
                    content: const Text(
                      '刷新订阅后选择线路，返回主页点击加速。连接成功后再次点击可断开代理。若线路不可用，请刷新并更换节点。',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('知道了'),
                      ),
                    ],
                  ),
                ),
              ),
              _SettingsItem(
                icon: Icons.logout_rounded,
                title: '退出账号',
                danger: true,
                onTap: () async {
                  final loggedOut = await ref
                      .read(authControllerProvider.notifier)
                      .logout();
                  if (!context.mounted) return;
                  if (loggedOut) {
                    context.goNamed(AppRoute.login.name);
                  } else {
                    showAppSnackbar(
                      context,
                      text: '流量同步或代理断开失败，请检查网络后重试退出',
                      type: AppSnackbarType.error,
                    );
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsItem extends StatelessWidget {
  const _SettingsItem({
    required this.icon,
    required this.title,
    required this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: ListTile(
        leading: Icon(
          icon,
          color: danger ? const Color(0xFFD14343) : const Color(0xFF30235E),
        ),
        title: Text(
          title,
          style: TextStyle(
            color: danger ? const Color(0xFFD14343) : const Color(0xFF202226),
            fontWeight: FontWeight.w600,
          ),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
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

String _rate(int value) => '${_bytes(value).replaceAll(' ', '')}/s';

String _nodeDisplayName(SubscriptionNode node) {
  final name = node.name.trim();
  return name.isEmpty || name == '${node.host}:${node.port}'
      ? '${node.type} 线路'
      : name;
}

String _settingsSubscriptionLabel(SubscriptionState state) {
  if (state is SubscriptionIdle || state is SubscriptionLoading) {
    return '正在同步订阅';
  }
  if (state is SubscriptionError) return '订阅同步失败';
  if (state is! SubscriptionReady) return '正在同步订阅';

  final status = state.status;
  if (status.canUse) return 'VIP 已激活';
  if (status.trafficTotal > 0 && status.trafficUsed >= status.trafficTotal) {
    return '流量已用完';
  }

  final paidUntil = DateTime.tryParse(status.paidUntil ?? '');
  if (paidUntil != null && !paidUntil.isAfter(DateTime.now())) {
    return '会员已到期';
  }
  return '订阅未激活';
}
