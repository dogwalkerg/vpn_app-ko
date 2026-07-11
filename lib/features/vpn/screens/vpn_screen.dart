// lib/features/vpn/screens/vpn_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vpn_app/core/extensions/context_ext.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/vpn/models/subscription_node.dart';
import 'package:vpn_app/features/vpn/providers/vpn_providers.dart';
import 'package:vpn_app/features/vpn/providers/subscription_nodes_provider.dart';
import '../widgets/animation_button.dart';
import '../../../ui/widgets/app_drawer.dart';

import '../../../ui/widgets/app_custom_appbar.dart';
import '../../../ui/widgets/themed_scaffold.dart';
import '../../subscription/widgets/subscription_banner.dart';

class VpnScreen extends ConsumerWidget {
  const VpnScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.tokens;

    final vpnState = ref.watch(vpnControllerProvider);
    final vpn = ref.read(vpnControllerProvider.notifier);
    final isAllowed = ref.watch(vpnAccessProvider);

    final isConnected = vpnState is VpnConnected;
    final isBusy = vpnState is VpnConnecting || vpnState is VpnDisconnecting;
    final error = vpnState is VpnError ? vpnState.message : null;
    final nodes = ref.watch(subscriptionNodesProvider);

    return ThemedScaffold(
      appBar: AppCustomAppBar(
        title: '自由云',
        leading: Builder(
          builder: (context) => IconButton(
            icon: Icon(Icons.menu, color: c.text),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      drawer: const AppDrawer(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(bottom: t.spacing.xl),
          child: Column(
            children: [
              const SubscriptionBanner(),
              SizedBox(height: t.spacing.md),
              nodes.when(
                data: (items) => _SelectedNodeCard(
                  nodes: items,
                  onTap: () => _showNodePicker(context, ref, items),
                ),
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
                error: (error, _) => _NodeLoadError(
                  onRetry: () => ref.invalidate(subscriptionNodesProvider),
                ),
              ),
              SizedBox(height: t.spacing.lg),
              if (isAllowed) ...[
                AnimationButton(
                  isConnected: isConnected,
                  isConnecting: isBusy,
                  onConnect: () async {
                    if (isConnected) {
                      await vpn.disconnectPressed();
                    } else {
                      await vpn.connectPressed();
                    }
                  },
                ),
                Text(
                  isBusy
                      ? '连接中...'
                      : isConnected
                      ? '已连接'
                      : '点击开启代理',
                  style: t.typography.h3.copyWith(
                    color: isConnected ? c.success : c.textMuted,
                  ),
                ),
                SizedBox(height: t.spacing.lg),
              ],
              if (error != null)
                Padding(
                  padding: t.spacing.all(t.spacing.md),
                  child: Text(
                    error,
                    style: t.typography.body.copyWith(
                      color: c.danger,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showNodePicker(
    BuildContext context,
    WidgetRef ref,
    List<SubscriptionNode> nodes,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.92,
        child: Column(
          children: [
            ListTile(
              title: const Text('选择线路'),
              trailing: IconButton(
                tooltip: '刷新节点',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  ref.invalidate(subscriptionNodesProvider);
                },
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _NodeList(nodes: nodes, closeOnSelect: true)),
          ],
        ),
      ),
    );
  }
}

class _SelectedNodeCard extends ConsumerWidget {
  final List<SubscriptionNode> nodes;
  final VoidCallback onTap;

  const _SelectedNodeCard({required this.nodes, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final c = context.colors;
    final selected = ref.watch(selectedSubscriptionNodeProvider);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.spacing.md),
      child: Material(
        color: c.bgLight,
        borderRadius: t.radii.brMd,
        child: InkWell(
          borderRadius: t.radii.brMd,
          onTap: nodes.isEmpty ? null : onTap,
          child: Padding(
            padding: t.spacing.all(t.spacing.md),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: c.bg,
                  child: Text(selected?.flag ?? '🌐'),
                ),
                SizedBox(width: t.spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selected?.name ?? (nodes.isEmpty ? '暂无可用线路' : '智能选择'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.typography.h3.copyWith(color: c.text),
                      ),
                      SizedBox(height: t.spacing.xs),
                      Text(
                        selected == null
                            ? '点击选择节点'
                            : '${selected.host}:${selected.port}',
                        style: t.typography.caption.copyWith(
                          color: c.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: c.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NodeLoadError extends StatelessWidget {
  final VoidCallback onRetry;
  const _NodeLoadError({required this.onRetry});

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onRetry,
    icon: const Icon(Icons.refresh_rounded),
    label: const Text('节点加载失败，点击重试'),
  );
}

class _NodeList extends ConsumerWidget {
  final List<SubscriptionNode> nodes;
  final bool closeOnSelect;

  const _NodeList({required this.nodes, this.closeOnSelect = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final c = context.colors;

    if (nodes.isEmpty) {
      return Center(
        child: Text(
          '暂无节点',
          style: t.typography.body.copyWith(color: c.textMuted),
        ),
      );
    }

    return ListView.separated(
      padding: EdgeInsets.fromLTRB(t.spacing.md, 0, t.spacing.md, t.spacing.lg),
      itemCount: nodes.length,
      separatorBuilder: (_, __) => SizedBox(height: t.spacing.sm),
      itemBuilder: (context, index) {
        final node = nodes[index];
        final selected = ref.watch(selectedSubscriptionNodeProvider);
        return _NodeTile(
          node: node,
          index: index + 1,
          selected: selected?.raw == node.raw,
          onTap: () {
            ref.read(selectedSubscriptionNodeProvider.notifier).state = node;
            if (closeOnSelect) Navigator.of(context).pop();
          },
        );
      },
    );
  }
}

class _NodeTile extends StatefulWidget {
  final SubscriptionNode node;
  final int index;
  final bool selected;
  final VoidCallback onTap;

  const _NodeTile({
    required this.node,
    required this.index,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_NodeTile> createState() => _NodeTileState();
}

class _NodeTileState extends State<_NodeTile> {
  late Future<int?> _latency;

  @override
  void initState() {
    super.initState();
    _latency = measureNodeLatency(widget.node);
  }

  @override
  void didUpdateWidget(covariant _NodeTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.raw != widget.node.raw) {
      _latency = measureNodeLatency(widget.node);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = context.colors;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(
          horizontal: t.spacing.md,
          vertical: t.spacing.sm,
        ),
        decoration: BoxDecoration(
          color: widget.selected
              ? const Color(0xFF4B4B4B)
              : const Color(0xFF3E3E3E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: widget.selected ? c.primary : Colors.transparent,
            width: 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 8,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                widget.node.flag,
                style: const TextStyle(fontSize: 24),
              ),
            ),
            SizedBox(width: t.spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.typography.body.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: t.spacing.xs * 0.5),
                  Row(
                    children: [
                      Icon(Icons.speed_rounded, color: c.info, size: 14),
                      SizedBox(width: t.spacing.xs),
                      Flexible(
                        child: FutureBuilder<int?>(
                          future: _latency,
                          builder: (context, snapshot) {
                            final status =
                                snapshot.connectionState ==
                                    ConnectionState.waiting
                                ? '测速中'
                                : snapshot.data == null
                                ? '超时'
                                : '${snapshot.data} ms';
                            return Text(
                              '${widget.node.host}:${widget.node.port} · $status',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.typography.caption.copyWith(
                                color: const Color(0xFFC9C9C9),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(width: t.spacing.sm),
            Text(
              '${widget.index}',
              style: t.typography.caption.copyWith(
                color: const Color(0xFFC9C9C9),
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(width: t.spacing.xs),
            Icon(Icons.groups_rounded, color: c.info, size: 17),
          ],
        ),
      ),
    );
  }
}
