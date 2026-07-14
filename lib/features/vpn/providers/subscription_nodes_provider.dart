import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vpn_app/core/api/coco_api.dart';
import 'package:vpn_app/core/config/app_config.dart';
import 'package:vpn_app/core/storage/shared_preferences_provider.dart';
import 'package:vpn_app/features/subscription/models/subscription_state.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/vpn/models/subscription_node.dart';

final selectedSubscriptionNodeProvider = StateProvider<SubscriptionNode?>(
  (ref) => null,
);

enum NodeSelectionMode { manual, smart }

const nodeSelectionModePreferenceKey = 'vpn.node_selection_mode.v1';

typedef NodeSelectionModePersistence =
    Future<void> Function(NodeSelectionMode mode);

final nodeSelectionModePersistenceProvider =
    Provider<NodeSelectionModePersistence>((ref) {
      return (mode) async {
        final preferences = ref.read(sharedPreferencesProvider);
        if (preferences == null) return;
        try {
          await preferences.setString(
            nodeSelectionModePreferenceKey,
            mode.name,
          );
        } catch (_) {}
      };
    }, name: 'nodeSelectionModePersistence');

final nodeSelectionModeProvider =
    StateNotifierProvider<NodeSelectionController, NodeSelectionMode>(
      NodeSelectionController.new,
      name: 'nodeSelectionMode',
    );

class NodeSelectionController extends StateNotifier<NodeSelectionMode> {
  NodeSelectionController(this.ref) : super(_initialSelectionMode(ref));

  final Ref ref;
  int _selectionGeneration = 0;

  Future<SubscriptionNode?> selectSmart({List<SubscriptionNode>? nodes}) async {
    final generation = ++_selectionGeneration;
    final suppliedRevision = ref.read(subscriptionNodesRevisionProvider);
    state = NodeSelectionMode.smart;
    await ref.read(nodeSelectionModePersistenceProvider)(
      NodeSelectionMode.smart,
    );
    if (generation != _selectionGeneration ||
        state != NodeSelectionMode.smart) {
      return null;
    }
    final currentRevision = ref.read(subscriptionNodesRevisionProvider);
    return _selectBestNode(
      suppliedRevision == currentRevision ? nodes : null,
      generation: generation,
    );
  }

  Future<SubscriptionNode?> refreshSmartSelection() async {
    if (state != NodeSelectionMode.smart) {
      return ref.read(selectedSubscriptionNodeProvider);
    }
    final generation = ++_selectionGeneration;
    return _selectBestNode(null, generation: generation);
  }

  Future<void> selectManual(SubscriptionNode node) async {
    _selectionGeneration++;
    state = NodeSelectionMode.manual;
    ref.read(selectedSubscriptionNodeProvider.notifier).state = node;
    await ref.read(nodeSelectionModePersistenceProvider)(
      NodeSelectionMode.manual,
    );
  }

  void cancelPendingSelection({bool clearNode = false}) {
    _selectionGeneration++;
    if (clearNode) {
      ref.read(selectedSubscriptionNodeProvider.notifier).state = null;
    }
  }

  Future<SubscriptionNode?> _selectBestNode(
    List<SubscriptionNode>? suppliedNodes, {
    required int generation,
  }) async {
    var candidates = suppliedNodes;
    while (generation == _selectionGeneration &&
        state == NodeSelectionMode.smart) {
      final activeRefresh = ref
          .read(subscriptionNodesRefreshControllerProvider.notifier)
          .activeRefresh;
      if (activeRefresh != null) {
        try {
          await activeRefresh;
        } catch (_) {}
        candidates = null;
        if (generation != _selectionGeneration ||
            state != NodeSelectionMode.smart) {
          return null;
        }
      }

      final revision = ref.read(subscriptionNodesRevisionProvider);
      final nodes = List<SubscriptionNode>.of(
        candidates ??
            ref.read(subscriptionNodesProvider).valueOrNull ??
            const <SubscriptionNode>[],
      ).where(isNodeCompatibleWithSmartSelection).toList();
      final previous = ref.read(selectedSubscriptionNodeProvider);
      final selected = await selectLowestLatencyNode(
        nodes: nodes,
        probe: ref.read(nodeLatencyProbeProvider),
        fallback: previous,
      );

      if (generation != _selectionGeneration ||
          state != NodeSelectionMode.smart) {
        return null;
      }
      if (revision != ref.read(subscriptionNodesRevisionProvider)) {
        candidates = null;
        continue;
      }
      if (selected != null) {
        ref.read(selectedSubscriptionNodeProvider.notifier).state = selected;
      }
      return selected;
    }
    return null;
  }
}

NodeSelectionMode _initialSelectionMode(Ref ref) {
  final stored = ref
      .read(sharedPreferencesProvider)
      ?.getString(nodeSelectionModePreferenceKey);
  return stored == NodeSelectionMode.smart.name
      ? NodeSelectionMode.smart
      : NodeSelectionMode.manual;
}

final subscriptionNodesRevisionProvider = StateProvider<int>((ref) => 0);
final subscriptionNodesRefreshControllerProvider =
    StateNotifierProvider<SubscriptionNodesRefreshController, bool>(
      SubscriptionNodesRefreshController.new,
      name: 'subscriptionNodesRefreshController',
    );
final subscriptionNodesRefreshingProvider = Provider<bool>(
  (ref) => ref.watch(subscriptionNodesRefreshControllerProvider),
  name: 'subscriptionNodesRefreshing',
);

typedef NodeLatencyProbe = Future<int?> Function(SubscriptionNode node);

final nodeLatencyProbeProvider = Provider<NodeLatencyProbe>(
  (_) => measureNodeLatency,
  name: 'nodeLatencyProbe',
);

bool isNodeCompatibleWithSmartSelection(
  SubscriptionNode node, {
  bool? desktopMihomo,
}) {
  final usesDesktopMihomo =
      desktopMihomo ?? (Platform.isWindows || Platform.isMacOS);
  return !usesDesktopMihomo || node.raw.toLowerCase().startsWith('vless://');
}

Future<SubscriptionNode?> selectLowestLatencyNode({
  required List<SubscriptionNode> nodes,
  required NodeLatencyProbe probe,
  SubscriptionNode? fallback,
}) async {
  if (nodes.isEmpty) return null;

  final measurements = await Future.wait(
    nodes.map((node) async {
      try {
        return (node: node, latency: await probe(node));
      } catch (_) {
        return (node: node, latency: null);
      }
    }),
  );

  SubscriptionNode? bestNode;
  int? bestLatency;
  for (final measurement in measurements) {
    final latency = measurement.latency;
    if (latency == null || latency <= 0) continue;

    final node = measurement.node;
    final isFaster = bestLatency == null || latency < bestLatency;
    final winsTie =
        latency == bestLatency &&
        bestNode != null &&
        (node.speedMbps > bestNode.speedMbps ||
            (node.speedMbps == bestNode.speedMbps &&
                node.load < bestNode.load));
    if (isFaster || winsTie) {
      bestNode = node;
      bestLatency = latency;
    }
  }
  if (bestNode != null) return bestNode;

  if (fallback != null) {
    for (final node in nodes) {
      if (node.raw == fallback.raw) return node;
    }
  }
  return nodes.first;
}

final subscriptionNodesProvider = FutureProvider<List<SubscriptionNode>>((
  ref,
) async {
  final subState = ref.watch(subscriptionControllerProvider);
  if (subState is! SubscriptionReady || !subState.status.canUse) {
    return const [];
  }

  final subUrl = subState.status.subUrl.trim();
  final text = subUrl.isEmpty || _isBackendSubscriptionUrl(subUrl)
      ? await ref.read(cocoApiProvider).subscriptionText()
      : (await Dio(
                  BaseOptions(
                    connectTimeout: const Duration(seconds: 10),
                    receiveTimeout: const Duration(seconds: 15),
                  ),
                ).get<String>(
                  subUrl,
                  options: Options(
                    responseType: ResponseType.plain,
                    headers: const {
                      'Cache-Control': 'no-cache',
                      'Pragma': 'no-cache',
                    },
                  ),
                ))
                .data ??
            '';
  final nodes = parseSubscriptionNodes(text);
  ref.read(subscriptionNodesRevisionProvider.notifier).state++;
  final selected = ref.read(selectedSubscriptionNodeProvider);
  final smartSelection =
      ref.read(nodeSelectionModeProvider) == NodeSelectionMode.smart;
  if (nodes.isNotEmpty && selected == null) {
    ref.read(selectedSubscriptionNodeProvider.notifier).state = nodes.first;
  } else if (nodes.isNotEmpty &&
      !smartSelection &&
      !nodes.any((node) => node.raw == selected?.raw)) {
    ref.read(selectedSubscriptionNodeProvider.notifier).state = nodes.first;
  } else if (nodes.isEmpty) {
    ref.read(selectedSubscriptionNodeProvider.notifier).state = null;
  }
  return nodes;
}, name: 'subscriptionNodes');

bool _isBackendSubscriptionUrl(String value) {
  final subscriptionUri = Uri.tryParse(value);
  final apiUri = Uri.tryParse(AppConfig.fromEnv().baseUrl);
  if (subscriptionUri == null || apiUri == null) return false;

  return subscriptionUri.scheme == apiUri.scheme &&
      subscriptionUri.host == apiUri.host &&
      subscriptionUri.port == apiUri.port &&
      subscriptionUri.path.endsWith('/v1/link');
}

Future<void> refreshSubscriptionNodes(WidgetRef ref) =>
    ref.read(subscriptionNodesRefreshControllerProvider.notifier).refresh();

class SubscriptionNodesRefreshController extends StateNotifier<bool> {
  SubscriptionNodesRefreshController(this.ref) : super(false);

  final Ref ref;
  Future<void>? _activeRefresh;

  Future<void>? get activeRefresh => _activeRefresh;

  Future<void> refresh() {
    final active = _activeRefresh;
    if (active != null) return active;

    state = true;
    ref.read(subscriptionNodesRevisionProvider.notifier).state++;
    late final Future<void> future;
    future = _performRefresh().whenComplete(() {
      if (identical(_activeRefresh, future)) {
        _activeRefresh = null;
        if (mounted) state = false;
      }
    });
    _activeRefresh = future;
    return future;
  }

  Future<void> _performRefresh() async {
    await ref
        .read(subscriptionControllerProvider.notifier)
        .fetch(forceRefresh: true);
    ref.invalidate(subscriptionNodesProvider);
    await ref.read(subscriptionNodesProvider.future);
  }
}

List<SubscriptionNode> parseSubscriptionNodes(String input) {
  final decoded = _decodeSubscription(input.trim());
  final lines = decoded
      .split(RegExp(r'[\r\n]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  final nodes = <SubscriptionNode>[];
  for (final line in lines) {
    final node = _parseNode(line);
    if (node != null) nodes.add(node);
  }
  return nodes;
}

String _decodeSubscription(String text) {
  if (text.contains('://')) return text;
  try {
    var normalized = text.replaceAll(RegExp(r'\s+'), '');
    final pad = normalized.length % 4;
    if (pad > 0) normalized += '=' * (4 - pad);
    return utf8.decode(base64.decode(normalized), allowMalformed: true);
  } catch (_) {
    return text;
  }
}

SubscriptionNode? _parseNode(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.scheme.isEmpty) return null;

  const supportedSchemes = {'vless', 'trojan', 'ss'};
  if (!supportedSchemes.contains(uri.scheme.toLowerCase()) ||
      uri.host.isEmpty ||
      uri.port <= 0 ||
      uri.port > 65535) {
    return null;
  }

  final type = uri.scheme.toUpperCase();
  final name = uri.fragment.isNotEmpty
      ? Uri.decodeComponent(uri.fragment)
      : '${uri.host}:${uri.port}';
  final country = _countryFromName(name);
  return SubscriptionNode(
    name: name,
    type: type,
    host: uri.host,
    port: uri.port,
    country: country.$1,
    flag: country.$2,
    speedMbps: 0,
    load: 0,
    raw: raw,
  );
}

Future<int?> measureNodeLatency(SubscriptionNode node) async {
  final stopwatch = Stopwatch()..start();
  Socket? socket;
  try {
    socket = await Socket.connect(
      node.host,
      node.port,
      timeout: const Duration(seconds: 5),
    );
    stopwatch.stop();
    return stopwatch.elapsedMilliseconds.clamp(1, 9999).toInt();
  } catch (_) {
    return null;
  } finally {
    socket?.destroy();
  }
}

(String, String) _countryFromName(String name) {
  final n = name.toLowerCase();
  if (n.contains('korea') ||
      n.contains('kr') ||
      n.contains('韩国') ||
      n.contains('高丽')) {
    return ('Korea Republic of', '🇰🇷');
  }
  if (n.contains('singapore') || n.contains('sg') || n.contains('新加坡')) {
    return ('Singapore', '🇸🇬');
  }
  if (n.contains('thailand') || n.contains('thai') || n.contains('泰国')) {
    return ('Thailand', '🇹🇭');
  }
  if (n.contains('japan') || n.contains('jp') || n.contains('日本')) {
    return ('Japan', '🇯🇵');
  }
  if (n.contains('united states') || n.contains('us') || n.contains('美国')) {
    return ('United States', '🇺🇸');
  }
  if (n.contains('hong kong') || n.contains('hk') || n.contains('香港')) {
    return ('Hong Kong', '🇭🇰');
  }
  if (n.contains('de ') || n.contains('germany') || n.contains('德国')) {
    return ('Germany', '🇩🇪');
  }
  if (n.contains('nl') || n.contains('netherlands') || n.contains('荷兰')) {
    return ('Netherlands', '🇳🇱');
  }
  return ('Global Node', '🌐');
}
