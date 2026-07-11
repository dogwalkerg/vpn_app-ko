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
        title: 'UgbuganVPN',
        leading: Builder(
          builder: (context) => IconButton(
            icon: Icon(Icons.menu, color: c.text),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      drawer: const AppDrawer(),
      body: SafeArea(
        child: Column(
          children: [
            const SubscriptionBanner(),
            SizedBox(height: t.spacing.md),
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
              SizedBox(height: t.spacing.md),
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
            Expanded(
              child: nodes.when(
                data: (items) => _NodeList(nodes: items),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Text(
                    '节点加载失败',
                    style: t.typography.body.copyWith(color: c.danger),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NodeList extends ConsumerWidget {
  final List<SubscriptionNode> nodes;

  const _NodeList({required this.nodes});

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
          onTap: () =>
              ref.read(selectedSubscriptionNodeProvider.notifier).state = node,
        );
      },
    );
  }
}

class _NodeTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = context.colors;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(
          horizontal: t.spacing.md,
          vertical: t.spacing.sm,
        ),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF4B4B4B) : const Color(0xFF3E3E3E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? c.primary : Colors.transparent,
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
              child: Text(node.flag, style: const TextStyle(fontSize: 24)),
            ),
            SizedBox(width: t.spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    node.country,
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
                        child: Text(
                          '${node.speedMbps.toStringAsFixed(1)} Mbps',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.typography.caption.copyWith(
                            color: const Color(0xFFC9C9C9),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(width: t.spacing.sm),
            Text(
              '$index',
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
