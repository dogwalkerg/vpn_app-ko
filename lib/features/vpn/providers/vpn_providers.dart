// lib/features/vpn/providers/vpn_providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_service.dart';
import '../repositories/vpn_repository.dart';
import '../repositories/vpn_repository_impl.dart';
import 'subscription_nodes_provider.dart';

export 'vpn_controller.dart';

final vpnRepositoryProvider = Provider<VpnRepository>((ref) {
  return VpnRepositoryImpl(
    ref.read(apiServiceProvider),
    selectedNode: () => ref.read(selectedSubscriptionNodeProvider),
    availableNodes: () =>
        ref.read(subscriptionNodesProvider).valueOrNull ?? const [],
    onNodeSelected: (node) =>
        ref.read(selectedSubscriptionNodeProvider.notifier).state = node,
  );
}, name: 'vpnRepository');
