import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
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

  test('resolves the server while preserving TLS serverName', () async {
    const source = '''
{
  "inbounds": [],
  "outbounds": [{
    "tag": "proxy",
    "protocol": "vless",
    "settings": {"vnext": [{"address": "localhost", "port": 443}]},
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {"serverName": ""}
    }
  }]
}
''';

    final prepared =
        jsonDecode(
              await prepareAndroidV2rayConfig(source, serverHost: 'localhost'),
            )
            as Map;
    final proxy = (prepared['outbounds'] as List).first as Map;
    final vnext = ((proxy['settings'] as Map)['vnext'] as List).first as Map;
    final tls = (proxy['streamSettings'] as Map)['tlsSettings'] as Map;

    expect(vnext['address'], anyOf('127.0.0.1', '::1'));
    expect(tls['serverName'], 'localhost');
  });

  test('generates compatible WS and Reality settings', () {
    final parser = FlutterV2ray.parseFromURL(
      'vless://00000000-0000-0000-0000-000000000001@example.com:443'
      '?type=ws&security=reality&pbk=test&sid=01#node',
    );
    final config = jsonDecode(parser.getFullConfiguration()) as Map;
    final proxy = (config['outbounds'] as List).first as Map;
    final stream = proxy['streamSettings'] as Map;

    expect((stream['wsSettings'] as Map)['path'], '/');
    expect((stream['realitySettings'] as Map)['fingerprint'], 'chrome');
  });

  test('verifies TLS certificates unless the URI explicitly opts out', () {
    Map tlsSettings(String query) {
      final parser = FlutterV2ray.parseFromURL(
        'vless://00000000-0000-0000-0000-000000000001@example.com:443'
        '?security=tls&type=ws$query#node',
      );
      final config = jsonDecode(parser.getFullConfiguration()) as Map;
      final proxy = (config['outbounds'] as List).first as Map;
      final stream = proxy['streamSettings'] as Map;
      return stream['tlsSettings'] as Map;
    }

    expect(tlsSettings('')['allowInsecure'], isFalse);
    expect(tlsSettings('&allowInsecure=1')['allowInsecure'], isTrue);
    expect(tlsSettings('&allowInsecure=false')['allowInsecure'], isFalse);
  });
}
