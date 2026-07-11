import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vpn_app/core/api/coco_api.dart';
import 'package:vpn_app/features/subscription/models/subscription_state.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/vpn/models/subscription_node.dart';

final subscriptionNodesProvider = FutureProvider<List<SubscriptionNode>>((ref) async {
  final subState = ref.watch(subscriptionControllerProvider);
  if (subState is! SubscriptionReady) return const [];

  final subUrl = subState.status.subUrl.trim();
  final text = subUrl.isEmpty
      ? await ref.read(cocoApiProvider).subscriptionText()
      : (await Dio().get<String>(subUrl, options: Options(responseType: ResponseType.plain))).data ?? '';
  return parseSubscriptionNodes(text);
}, name: 'subscriptionNodes');

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

  final type = uri.scheme.toUpperCase();
  final name = uri.fragment.isNotEmpty ? Uri.decodeComponent(uri.fragment) : '${uri.host}:${uri.port}';
  final country = _countryFromName(name);
  final seed = raw.codeUnits.fold<int>(0, (a, b) => (a + b) & 0x7fffffff);
  final random = Random(seed);
  return SubscriptionNode(
    name: name,
    type: type,
    host: uri.host,
    port: uri.port,
    country: country.$1,
    flag: country.$2,
    speedMbps: 60 + random.nextInt(360) + random.nextDouble(),
    load: 10 + random.nextInt(250),
    raw: raw,
  );
}

(String, String) _countryFromName(String name) {
  final n = name.toLowerCase();
  if (n.contains('korea') || n.contains('kr') || n.contains('韩国') || n.contains('高丽')) return ('Korea Republic of', '🇰🇷');
  if (n.contains('singapore') || n.contains('sg') || n.contains('新加坡')) return ('Singapore', '🇸🇬');
  if (n.contains('thailand') || n.contains('thai') || n.contains('泰国')) return ('Thailand', '🇹🇭');
  if (n.contains('japan') || n.contains('jp') || n.contains('日本')) return ('Japan', '🇯🇵');
  if (n.contains('united states') || n.contains('us') || n.contains('美国')) return ('United States', '🇺🇸');
  if (n.contains('hong kong') || n.contains('hk') || n.contains('香港')) return ('Hong Kong', '🇭🇰');
  if (n.contains('de ') || n.contains('germany') || n.contains('德国')) return ('Germany', '🇩🇪');
  if (n.contains('nl') || n.contains('netherlands') || n.contains('荷兰')) return ('Netherlands', '🇳🇱');
  return ('Global Node', '🌐');
}
