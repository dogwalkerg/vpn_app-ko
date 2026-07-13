import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vpn_app/core/api/coco_api.dart';
import 'package:vpn_app/core/config/app_config.dart';
import 'package:vpn_app/features/subscription/models/subscription_state.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/vpn/models/subscription_node.dart';

final selectedSubscriptionNodeProvider = StateProvider<SubscriptionNode?>(
  (ref) => null,
);

final subscriptionNodesRefreshingProvider = StateProvider<bool>((ref) => false);

typedef NodeLatencyProbe = Future<int?> Function(SubscriptionNode node);

final nodeLatencyProbeProvider = Provider<NodeLatencyProbe>(
  (_) => measureNodeLatency,
  name: 'nodeLatencyProbe',
);

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
  final selected = ref.read(selectedSubscriptionNodeProvider);
  if (nodes.isNotEmpty &&
      (selected == null || !nodes.any((node) => node.raw == selected.raw))) {
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

Future<void> refreshSubscriptionNodes(WidgetRef ref) async {
  if (ref.read(subscriptionNodesRefreshingProvider)) return;

  ref.read(subscriptionNodesRefreshingProvider.notifier).state = true;
  try {
    await ref
        .read(subscriptionControllerProvider.notifier)
        .fetch(forceRefresh: true);
    ref.invalidate(subscriptionNodesProvider);
    await ref.read(subscriptionNodesProvider.future);
  } finally {
    ref.read(subscriptionNodesRefreshingProvider.notifier).state = false;
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
