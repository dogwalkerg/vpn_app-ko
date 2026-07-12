import 'dart:convert';

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
