import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/features/vpn/providers/subscription_nodes_provider.dart';

void main() {
  group('parseSubscriptionNodes', () {
    test('parses supported nodes from a base64 subscription', () {
      const raw =
          'vless://user@example.com:443?security=tls&type=ws#Hong%20Kong\n'
          'trojan://secret@example.net:8443?security=tls#Singapore';
      final encoded = base64Encode(utf8.encode(raw));

      final nodes = parseSubscriptionNodes(encoded);

      expect(nodes, hasLength(2));
      expect(nodes.first.name, 'Hong Kong');
      expect(nodes.first.host, 'example.com');
      expect(nodes.first.port, 443);
      expect(nodes.last.type, 'TROJAN');
    });

    test('rejects YAML sections and malformed nodes', () {
      const input = '''
proxies:
rules:
vless://user@:443#MissingHost
vless://user@example.com:0#MissingPort
https://example.com:443/not-a-proxy
ss://method:password@example.org:8388#Valid
''';

      final nodes = parseSubscriptionNodes(input);

      expect(nodes, hasLength(1));
      expect(nodes.single.type, 'SS');
      expect(nodes.single.port, 8388);
    });

    test('parses a standard base64 VMess node', () {
      final payload = base64Encode(
        utf8.encode(
          jsonEncode({
            'v': '2',
            'ps': 'Japan VMess',
            'add': 'vmess.example.com',
            'port': '8443',
            'id': '11111111-1111-1111-1111-111111111111',
            'aid': '0',
            'net': 'ws',
            'type': 'none',
            'host': 'cdn.example.com',
            'path': '/ws',
            'tls': 'tls',
          }),
        ),
      ).replaceAll('=', '');

      final nodes = parseSubscriptionNodes('vmess://$payload');

      expect(nodes, hasLength(1));
      expect(nodes.single.name, 'Japan VMess');
      expect(nodes.single.type, 'VMESS');
      expect(nodes.single.host, 'vmess.example.com');
      expect(nodes.single.port, 8443);
    });
  });
}
