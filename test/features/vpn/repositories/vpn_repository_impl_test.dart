import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/features/vpn/models/subscription_node.dart';
import 'package:vpn_app/features/vpn/repositories/vpn_repository_impl.dart';

void main() {
  test('single-flight operation shares concurrent stops and resets', () async {
    final operation = SingleFlightVoidOperation();
    final release = Completer<void>();
    var calls = 0;

    Future<void> stop() {
      calls++;
      return release.future;
    }

    final first = operation.run(stop);
    final second = operation.run(stop);

    expect(identical(first, second), isTrue);
    expect(calls, 1);

    release.complete();
    await Future.wait([first, second]);
    await operation.run(() async {
      calls++;
    });

    expect(calls, 2);
  });

  test('single-flight operation resets after a failed stop', () async {
    final operation = SingleFlightVoidOperation();
    var calls = 0;

    await expectLater(
      operation.run(() async {
        calls++;
        throw StateError('stop failed');
      }),
      throwsStateError,
    );
    await operation.run(() async {
      calls++;
    });

    expect(calls, 2);
  });

  group('connectionCandidates', () {
    test('manual mode returns only the selected node', () {
      final selected = _node('selected', port: 8443);
      final available = [
        _node('fallback-2096', port: 2096),
        selected,
        _node('fallback-443', port: 443),
      ];

      final candidates = connectionCandidates(
        selected: selected,
        available: available,
        allowFallback: false,
      );

      expect(candidates, [selected]);
    });

    test('desktop smart fallback preserves subscription order', () {
      final selected = _node('selected', port: 8443);
      final first = _node('first-default-port', port: 8080);
      final second = _node('second-2096', port: 2096);
      final third = _node('third-443', port: 443);

      final candidates = connectionCandidates(
        selected: selected,
        available: [first, selected, second, third],
        allowFallback: true,
        prioritizeAndroidPorts: false,
      );

      expect(candidates, [selected, first, second, third]);
    });

    test('Android smart fallback uses stable port priority ordering', () {
      final selected = _node('selected', port: 8443);
      final firstDefault = _node('first-default', port: 8080);
      final first2096 = _node('first-2096', port: 2096);
      final first2053 = _node('first-2053', port: 2053);
      final second2096 = _node('second-2096', port: 2096);
      final first443 = _node('first-443', port: 443);
      final secondDefault = _node('second-default', port: 8443);
      final second2053Group = _node('second-2087', port: 2087);

      final candidates = connectionCandidates(
        selected: selected,
        available: [
          firstDefault,
          first2096,
          selected,
          first2053,
          second2096,
          first443,
          secondDefault,
          second2053Group,
        ],
        allowFallback: true,
        prioritizeAndroidPorts: true,
      );

      expect(candidates, [
        selected,
        first2096,
        second2096,
        first443,
        first2053,
        second2053Group,
        firstDefault,
        secondDefault,
      ]);
    });
  });

  test('mihomoCoreNodes gives duplicate display names unique identities', () {
    final first = _node('duplicate', port: 2096);
    final second = _node('duplicate', port: 443);
    final repeatedUri = SubscriptionNode(
      name: 'renamed duplicate',
      type: first.type,
      host: first.host,
      port: first.port,
      country: first.country,
      flag: first.flag,
      speedMbps: first.speedMbps,
      load: first.load,
      raw: first.raw,
    );

    final coreNodes = mihomoCoreNodes([first, second, repeatedUri]);

    expect(coreNodes, hasLength(2));
    expect(coreNodes.map((item) => item.coreName).toSet(), hasLength(2));
    expect(coreNodes[0].coreName, startsWith('duplicate ['));
    expect(coreNodes[1].coreName, startsWith('duplicate ['));
  });

  group('clashNodeSetsMatch', () {
    test('matches the same nodes regardless of order or duplicates', () {
      expect(
        clashNodeSetsMatch(
          ['Japan 1', 'Japan 2', 'Japan 1'],
          ['Japan 2', 'Japan 1'],
        ),
        isTrue,
      );
    });

    test('rejects missing or unexpected nodes', () {
      expect(clashNodeSetsMatch(['Japan 1', 'Japan 2'], ['Japan 1']), isFalse);
      expect(
        clashNodeSetsMatch(
          ['Japan 1', 'Japan 2'],
          ['Japan 1', 'Japan 2', 'CF 6'],
        ),
        isFalse,
      );
    });
  });

  test('encodePowerShellCommand produces Windows PowerShell UTF-16LE', () {
    const script = "Write-Output 'Osca 日本节点'";
    final bytes = base64Decode(encodePowerShellCommand(script));
    final codeUnits = <int>[
      for (var index = 0; index < bytes.length; index += 2)
        bytes[index] | (bytes[index + 1] << 8),
    ];

    expect(String.fromCharCodes(codeUnits), script);
  });

  group('macOSProxyNeedsRestore', () {
    test('restores a persisted snapshot after aggregate ownership is lost', () {
      expect(
        macOSProxyNeedsRestore(usesLocalCore: false, snapshotAvailable: true),
        isTrue,
      );
    });

    test('restores a managed endpoint even without a snapshot marker', () {
      expect(
        macOSProxyNeedsRestore(usesLocalCore: true, snapshotAvailable: false),
        isTrue,
      );
    });

    test('does not restore an unrelated proxy without a snapshot', () {
      expect(
        macOSProxyNeedsRestore(usesLocalCore: false, snapshotAvailable: false),
        isFalse,
      );
    });
  });

  group('macOSProxyRestoreSucceeded', () {
    test('accepts a complete conflict-free restore', () {
      expect(
        macOSProxyRestoreSucceeded(
          restored: true,
          usesLocalCore: false,
          conflicts: const [],
        ),
        isTrue,
      );
    });

    test('rejects a partial restore with user conflicts', () {
      expect(
        macOSProxyRestoreSucceeded(
          restored: false,
          usesLocalCore: false,
          conflicts: const ['Wi-Fi: HTTPProxy'],
        ),
        isFalse,
      );
    });

    test('rejects an incomplete restore without reported conflicts', () {
      expect(
        macOSProxyRestoreSucceeded(
          restored: false,
          usesLocalCore: false,
          conflicts: const [],
        ),
        isFalse,
      );
    });

    test('rejects a restore that still points to the local core', () {
      expect(
        macOSProxyRestoreSucceeded(
          restored: true,
          usesLocalCore: true,
          conflicts: const [],
        ),
        isFalse,
      );
    });
  });

  test('MihomoControllerClient uses the expected controller API', () async {
    final requests = <_RecordedRequest>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add(
        _RecordedRequest(
          method: request.method,
          uri: request.uri,
          body: body.isEmpty ? null : jsonDecode(body),
        ),
      );

      if (request.method == 'GET' && request.uri.path == '/proxies/Proxy') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'all': ['Japan 2', 'CF 6'],
          }),
        );
      } else {
        request.response.statusCode = HttpStatus.noContent;
      }
      await request.response.close();
    });
    final client = MihomoControllerClient(
      baseUrl: 'http://${server.address.address}:${server.port}',
    );

    await client.reloadConfig(r'C:\Osca\runtime\config.yaml');
    final nodeNames = await client.proxyGroupNodeNames();
    await client.selectNode('Japan 2');

    expect(nodeNames, {'Japan 2', 'CF 6'});
    expect(requests, hasLength(3));
    expect(requests[0].method, 'PUT');
    expect(requests[0].uri.path, '/configs');
    expect(requests[0].uri.queryParameters, {'force': 'true'});
    expect(requests[0].body, {'path': r'C:\Osca\runtime\config.yaml'});
    expect(requests[1].method, 'GET');
    expect(requests[1].uri.path, '/proxies/Proxy');
    expect(requests[2].method, 'PUT');
    expect(requests[2].uri.path, '/proxies/Proxy');
    expect(requests[2].body, {'name': 'Japan 2'});
  });
}

SubscriptionNode _node(String name, {required int port}) => SubscriptionNode(
  name: name,
  type: 'vless',
  host: 'example.com',
  port: port,
  country: 'JP',
  flag: '',
  speedMbps: 0,
  load: 0,
  raw: 'vless://$name@example.com:$port#$name',
);

class _RecordedRequest {
  const _RecordedRequest({
    required this.method,
    required this.uri,
    required this.body,
  });

  final String method;
  final Uri uri;
  final Object? body;
}
