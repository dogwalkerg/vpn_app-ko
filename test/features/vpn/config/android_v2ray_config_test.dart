import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/features/vpn/config/android_v2ray_config.dart';

void main() {
  test('uses the ports required by Android tun2socks', () {
    const source = '''
{
  "inbounds": [
    {"tag": "in_proxy", "protocol": "socks", "port": 1080},
    {"tag": "old_http", "protocol": "http", "port": 8080}
  ],
  "outbounds": [{"tag": "proxy", "protocol": "vless"}]
}
''';

    final config = jsonDecode(buildAndroidV2rayConfig(source)) as Map;
    final inbounds = (config['inbounds'] as List).cast<Map>();
    final socks = inbounds.singleWhere((item) => item['protocol'] == 'socks');
    final http = inbounds.singleWhere((item) => item['protocol'] == 'http');

    expect(socks['listen'], '127.0.0.1');
    expect(socks['port'], 10808);
    expect((socks['settings'] as Map)['udp'], isTrue);
    expect(http['port'], 10809);
    expect(inbounds, hasLength(2));
    expect((config['policy'] as Map)['system'], {
      'statsOutboundUplink': true,
      'statsOutboundDownlink': true,
    });
    expect(config['stats'], isEmpty);
  });
}
