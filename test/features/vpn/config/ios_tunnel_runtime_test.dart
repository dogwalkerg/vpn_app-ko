import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:flutter_vless/flutter_vless_ios.dart';

void main() {
  test('iOS VlessStatus preserves the native Packet Tunnel session id', () {
    final native = IosVlessStatus.fromEvent({
      'duration': 10,
      'uploadSpeed': 2,
      'downloadSpeed': 3,
      'upload': 100,
      'download': 200,
      'state': 'CONNECTED',
      'sessionId': 'native-session-a',
    });

    final status = VlessStatus.fromPlatform(native);

    expect(status.sessionId, 'native-session-a');
    expect(status.upload, 100);
    expect(status.download, 200);
    expect(status.connectionState, VlessConnectionState.connected);
  });

  test('tunnel health is valid only with an exact HTTP 204', () {
    final healthy = IosTunnelHealth.fromMap({
      'sessionId': 'native-session-a',
      'healthy': true,
      'xrayRunning': true,
      'hevRunning': true,
      'socksInboundReady': true,
      'providerHttpStatusCode': 204,
      'httpStatusCode': 204,
      'httpStatusLine': 'HTTP/1.1 204 No Content',
      'checkedAtMilliseconds': 1000,
    });
    final redirected = IosTunnelHealth.fromMap({
      // Even a malformed native `healthy=true` cannot make a redirect pass.
      'healthy': true,
      'providerHttpStatusCode': 204,
      'httpStatusCode': 302,
      'failureReason': 'Expected HTTP 204, received 302',
    });

    expect(healthy.hasExactHttp204, isTrue);
    expect(redirected.hasExactHttp204, isFalse);
    expect(redirected.failureReason, contains('302'));
    expect(
      IosTunnelHealth.fromMap({
        'healthy': true,
        'providerHttpStatusCode': 500,
        'httpStatusCode': 204,
      }).hasExactHttp204,
      isFalse,
    );
  });

  group('iOS tunnel runtime readiness', () {
    IosTunnelHealth health({
      bool healthy = false,
      bool xrayRunning = true,
      bool hevRunning = true,
      bool socksInboundReady = true,
      int? providerHttpStatusCode,
      int? httpStatusCode,
    }) => IosTunnelHealth.fromMap({
      'healthy': healthy,
      'xrayRunning': xrayRunning,
      'hevRunning': hevRunning,
      'socksInboundReady': socksInboundReady,
      'providerHttpStatusCode': providerHttpStatusCode,
      'httpStatusCode': httpStatusCode,
      'failureReason': 'Public probe timed out',
    });

    test('public probe degradation does not invalidate a ready runtime', () {
      final degraded = health();

      expect(degraded.runtimeReady, isTrue);
      expect(degraded.hasExactHttp204, isFalse);
    });

    test('all local native components must remain available', () {
      expect(health(xrayRunning: false).runtimeReady, isFalse);
      expect(health(hevRunning: false).runtimeReady, isFalse);
      expect(health(socksInboundReady: false).runtimeReady, isFalse);

      // A successful public probe cannot hide a failed native component.
      expect(
        health(
          healthy: true,
          xrayRunning: false,
          providerHttpStatusCode: 204,
          httpStatusCode: 204,
        ).runtimeReady,
        isFalse,
      );
    });
  });

  test('runtime snapshot restores persistent session totals', () {
    final snapshot = IosTunnelSnapshot.fromMap({
      'state': 'CONNECTED',
      'enabled': true,
      'vpnStatus': 3,
      'session': {
        'sessionId': 'native-session-a',
        'running': true,
        'uploadBytes': 4096,
        'downloadBytes': 8192,
        'startedAtMilliseconds': 1000,
        'updatedAtMilliseconds': 2000,
      },
      'health': {
        'sessionId': 'native-session-a',
        'healthy': true,
        'xrayRunning': true,
        'hevRunning': true,
        'socksInboundReady': true,
        'httpStatusCode': 204,
        'httpStatusLine': 'HTTP/1.1 204 No Content',
        'checkedAtMilliseconds': 2000,
      },
    });

    expect(snapshot.sessionId, 'native-session-a');
    expect(snapshot.running, isTrue);
    expect(snapshot.uploadBytes + snapshot.downloadBytes, 12288);
    expect(snapshot.health?.healthy, isTrue);
    // App Group snapshots contain provider health only. The authoritative
    // dual-probe result is returned by getTunnelHealth().
    expect(snapshot.health?.hasExactHttp204, isFalse);
  });

  test('late pre-stop traffic cannot publish a stale connected event', () {
    final source = File(
      'third_party/flutter_vless_ios/ios/flutter_vless/'
      'Sources/flutter_vless/FlutterVlessPlugin.swift',
    ).readAsStringSync();
    final start = source.indexOf(
      'private func prepareFinalTrafficSnapshotAndStop',
    );
    final end = source.indexOf('private func scheduleStopTimeout', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final stopBlock = source.substring(start, end);
    expect(stopBlock, contains('guard self.stopPreparationInFlight'));
    expect(stopBlock, contains('status != .disconnected'));
    expect(stopBlock, contains('status != .invalid'));
    expect(stopBlock, contains('state: "DISCONNECTING"'));
    expect(stopBlock, isNot(contains('state: "CONNECTED"')));
  });

  test('iOS health probes are diagnostic-only under sustained load', () {
    final provider = File(
      'ios/XrayTunnel/PacketTunnelProvider.swift',
    ).readAsStringSync();
    final plugin = File(
      'third_party/flutter_vless_ios/ios/flutter_vless/'
      'Sources/flutter_vless/FlutterVlessPlugin.swift',
    ).readAsStringSync();

    expect(provider, contains('logStartupHealthDiagnostic()'));
    expect(provider, contains('message == "xray_health"'));
    expect(provider, isNot(contains('startContinuousHealthMonitoring')));
    expect(provider, isNot(contains('consecutiveHealthFailures')));
    expect(provider, isNot(contains('handleHealthResult')));
    expect(plugin, isNot(contains('pollTunnelHealthForDiagnostics')));
  });

  test('iOS uses the verified v1.0.35 route and HEV stop policy', () {
    final provider = File(
      'ios/XrayTunnel/PacketTunnelProvider.swift',
    ).readAsStringSync();

    expect(provider, contains('settings.ipv6Settings = nil'));
    expect(
      provider,
      contains('routes.append(contentsOf: TunnelRuntimePolicy.dnsServers.map'),
    );
    expect(provider, isNot(contains('NEIPv6Route.default()')));
    expect(provider, isNot(contains('asyncAfter(deadline: .now() + 0.1)')));
  });
}
