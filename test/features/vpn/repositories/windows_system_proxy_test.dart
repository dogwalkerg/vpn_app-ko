import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/features/vpn/repositories/vpn_repository_impl.dart';

void main() {
  group('DesktopHealthTracker', () {
    test('fails only after three consecutive local health misses', () {
      final tracker = DesktopHealthTracker();

      expect(
        tracker.recordLocalAvailability(false),
        DesktopHealthDisposition.degraded,
      );
      expect(
        tracker.recordLocalAvailability(false),
        DesktopHealthDisposition.degraded,
      );
      expect(tracker.localFailureCount, 2);
      expect(
        tracker.recordLocalAvailability(false),
        DesktopHealthDisposition.failed,
      );
      expect(tracker.localFailureCount, 3);
    });

    test('a healthy local cycle resets the consecutive failure count', () {
      final tracker = DesktopHealthTracker();

      tracker.recordLocalAvailability(false);
      tracker.recordLocalAvailability(false);
      expect(
        tracker.recordLocalAvailability(true),
        DesktopHealthDisposition.healthy,
      );
      expect(tracker.localFailureCount, 0);
      expect(
        tracker.recordLocalAvailability(false),
        DesktopHealthDisposition.degraded,
      );
      expect(tracker.localFailureCount, 1);
    });

    test('upstream probe misses stay degraded and recovery clears them', () {
      final tracker = DesktopHealthTracker();

      for (var index = 0; index < 10; index++) {
        expect(
          tracker.recordUpstreamReachability(false),
          DesktopHealthDisposition.degraded,
        );
      }
      expect(tracker.upstreamFailureCount, 10);
      expect(
        tracker.recordUpstreamReachability(true),
        DesktopHealthDisposition.healthy,
      );
      expect(tracker.upstreamFailureCount, 0);
    });

    test('reset clears local and upstream degraded state', () {
      final tracker = DesktopHealthTracker();
      tracker.recordLocalAvailability(false);
      tracker.recordUpstreamReachability(false);

      tracker.reset();

      expect(tracker.localFailureCount, 0);
      expect(tracker.upstreamFailureCount, 0);
    });
  });

  group('windowsProxyServerUsesLocalCore', () {
    test('accepts the exact local core endpoint', () {
      expect(windowsProxyServerUsesLocalCore('127.0.0.1:7890'), isTrue);
      expect(windowsProxyServerUsesLocalCore('localhost:7890'), isTrue);
    });

    test('accepts a multi-protocol local core endpoint', () {
      expect(
        windowsProxyServerUsesLocalCore(
          'http=127.0.0.1:7890;https=127.0.0.1:7890;'
          'socks=127.0.0.1:7890',
        ),
        isTrue,
      );
    });

    test('rejects another system proxy', () {
      expect(
        windowsProxyServerUsesLocalCore('proxy.example.com:8080'),
        isFalse,
      );
    });

    test('does not accept the local endpoint as a substring', () {
      expect(
        windowsProxyServerUsesLocalCore(
          'proxy.example.com:8080/127.0.0.1:7890',
        ),
        isFalse,
      );
    });

    test('does not accept a mixed proxy owned by another app', () {
      expect(
        windowsProxyServerUsesLocalCore(
          'http=127.0.0.1:7890;https=proxy.example.com:8080',
        ),
        isFalse,
      );
    });
  });
}
