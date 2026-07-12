import 'dart:convert';
import 'dart:io';

String buildAndroidV2rayConfig(String source) {
  final config = (jsonDecode(source) as Map).cast<String, dynamic>();
  final inbounds = ((config['inbounds'] as List?) ?? const [])
      .map((item) => (item as Map).cast<String, dynamic>())
      .toList();
  inbounds.removeWhere(
    (inbound) =>
        inbound['protocol'] == 'socks' || inbound['protocol'] == 'http',
  );
  inbounds.add({
    'tag': 'socks',
    'protocol': 'socks',
    'listen': '127.0.0.1',
    'port': 10808,
    'settings': <String, dynamic>{'auth': 'noauth', 'udp': true},
    'sniffing': <String, dynamic>{
      'enabled': true,
      'destOverride': ['http', 'tls'],
    },
  });
  inbounds.add({
    'tag': 'http',
    'protocol': 'http',
    'listen': '127.0.0.1',
    'port': 10809,
    'settings': <String, dynamic>{},
  });
  config['inbounds'] = inbounds;
  config['dns'] = {
    'queryStrategy': 'UseIP',
    'servers': ['1.1.1.1', '8.8.8.8'],
  };
  final routing =
      (config['routing'] as Map?)?.cast<String, dynamic>() ??
      <String, dynamic>{};
  routing['domainStrategy'] = 'IPIfNonMatch';
  config['routing'] = routing;
  config['policy'] = {
    'system': {'statsOutboundUplink': true, 'statsOutboundDownlink': true},
  };
  config['stats'] = <String, dynamic>{};
  return jsonEncode(config);
}

Future<String> prepareAndroidV2rayConfig(
  String source, {
  required String serverHost,
}) async {
  final config =
      jsonDecode(buildAndroidV2rayConfig(source)) as Map<String, dynamic>;
  final outbounds = (config['outbounds'] as List?) ?? const [];
  if (outbounds.isEmpty) return jsonEncode(config);

  final proxy = (outbounds.first as Map).cast<String, dynamic>();
  final stream = (proxy['streamSettings'] as Map?)?.cast<String, dynamic>();
  final security = stream?['security']?.toString();
  final securityKey = security == 'reality' ? 'realitySettings' : 'tlsSettings';
  final securitySettings = (stream?[securityKey] as Map?)
      ?.cast<String, dynamic>();
  if ((security == 'tls' || security == 'reality') &&
      securitySettings != null &&
      (securitySettings['serverName']?.toString().isEmpty ?? true)) {
    securitySettings['serverName'] = serverHost;
  }

  try {
    final addresses = await InternetAddress.lookup(
      serverHost,
    ).timeout(const Duration(seconds: 5));
    final resolved = addresses
        .where((address) => address.type == InternetAddressType.IPv4)
        .followedBy(addresses)
        .firstOrNull;
    final settings = (proxy['settings'] as Map?)?.cast<String, dynamic>();
    final vnext = (settings?['vnext'] as List?) ?? const [];
    if (resolved != null && vnext.isNotEmpty) {
      (vnext.first as Map)['address'] = resolved.address;
    }
  } catch (_) {
    // Xray can still resolve the original hostname when pre-resolution fails.
  }
  return jsonEncode(config);
}
