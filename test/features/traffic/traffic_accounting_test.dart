import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpn_app/core/api/api_service.dart';
import 'package:vpn_app/core/api/coco_api.dart';
import 'package:vpn_app/core/network/connectivity_provider.dart';
import 'package:vpn_app/features/auth/providers/auth_providers.dart';
import 'package:vpn_app/features/subscription/models/subscription_state.dart';
import 'package:vpn_app/features/subscription/models/subscription_status.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/subscription/repositories/subscription_repository.dart';
import 'package:vpn_app/features/traffic/models/traffic_accounting_state.dart';
import 'package:vpn_app/features/traffic/providers/traffic_accounting_provider.dart';
import 'package:vpn_app/features/vpn/platform/vpn_channel.dart';
import 'package:vpn_app/features/vpn/providers/subscription_nodes_provider.dart';
import 'package:vpn_app/features/vpn/providers/vpn_controller.dart';
import 'package:wireguard_flutter/wireguard_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // Let disposal work from the previous test drain before replacing the
    // shared-preferences mock. Native cursor writes are intentionally durable.
    await Future<void>.delayed(Duration.zero);
    SharedPreferences.setMockInitialValues({});
    await (await SharedPreferences.getInstance()).clear();
  });

  test('state derives and accumulates session totals', () {
    const state = TrafficAccountingState(
      sessionUploadBytes: 120,
      sessionDownloadBytes: 345,
      pendingBytes: 465,
      restriction: CocoTrafficRestriction.quotaOrExpired,
      notice: 'blocked',
    );

    final accumulated = state.copyWith(
      sessionUploadBytes: state.sessionUploadBytes + 80,
      sessionDownloadBytes: state.sessionDownloadBytes + 55,
      pendingBytes: state.pendingBytes + 135,
      clearRestriction: true,
      clearNotice: true,
    );

    expect(state.sessionBytes, 465);
    expect(accumulated.sessionUploadBytes, 200);
    expect(accumulated.sessionDownloadBytes, 400);
    expect(accumulated.sessionBytes, 600);
    expect(accumulated.pendingBytes, 600);
    expect(accumulated.restriction, isNull);
    expect(accumulated.notice, isNull);
  });

  test('controller batching policy matches the accounting contract', () {
    expect(TrafficAccountingController.reportThresholdBytes, 100 * 1024 * 1024);
    expect(
      TrafficAccountingController.reportInterval,
      const Duration(minutes: 15),
    );
    expect(
      TrafficAccountingController.heartbeatInterval,
      const Duration(minutes: 5),
    );
  });

  test(
    'controller accumulates native counter deltas without double counting',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final container = ProviderContainer(
        overrides: [
          cocoApiProvider.overrideWithValue(CocoApi(_NeverApiService())),
          vpnAccessProvider.overrideWithValue(true),
          vpnControllerProvider.overrideWith((ref) => _TestVpnController(ref)),
        ],
      );
      addTearDown(container.dispose);
      final accounting = container.read(trafficAccountingProvider.notifier);
      final vpn =
          container.read(vpnControllerProvider.notifier) as _TestVpnController;
      await Future<void>.delayed(Duration.zero);
      vpn.emitConnected();
      await Future<void>.delayed(Duration.zero);

      VpnChannel().report(
        VpnStatusEvent(
          stage: VpnStage.connected,
          sessionId: 'session-a',
          uploadBytesTotal: 100,
          downloadBytesTotal: 200,
          uploadBytesPerSecond: 10,
          downloadBytesPerSecond: 20,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      var state = accounting.state;
      expect(state.connected, isTrue);
      expect(state.sessionUploadBytes, 100);
      expect(state.sessionDownloadBytes, 200);
      expect(state.pendingBytes, 300);
      expect(state.uploadBytesPerSecond, 10);
      expect(state.downloadBytesPerSecond, 20);

      VpnChannel().report(
        VpnStatusEvent(
          stage: VpnStage.connected,
          sessionId: 'session-a',
          uploadBytesTotal: 150,
          downloadBytesTotal: 260,
          uploadBytesPerSecond: 50,
          downloadBytesPerSecond: 60,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      state = accounting.state;
      expect(state.sessionUploadBytes, 150);
      expect(state.sessionDownloadBytes, 260);
      expect(state.pendingBytes, 410);

      VpnChannel().report(
        VpnStatusEvent(
          stage: VpnStage.connected,
          sessionId: 'session-a',
          uploadBytesTotal: 10,
          downloadBytesTotal: 10,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      state = accounting.state;
      expect(state.sessionUploadBytes, 150);
      expect(state.sessionDownloadBytes, 260);
      expect(state.pendingBytes, 410);

      VpnChannel().report(
        VpnStatusEvent(
          stage: VpnStage.connected,
          sessionId: 'session-b',
          uploadBytesTotal: 20,
          downloadBytesTotal: 30,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      state = accounting.state;
      expect(state.sessionUploadBytes, 170);
      expect(state.sessionDownloadBytes, 290);
      expect(state.sessionBytes, 460);
      expect(state.pendingBytes, 460);

      VpnChannel().report(
        VpnStatusEvent(
          stage: VpnStage.disconnecting,
          sessionId: 'session-b',
          uploadBytesTotal: 25,
          downloadBytesTotal: 35,
        ),
      );
      await _waitUntil(() => accounting.state.pendingBytes == 470);
      expect(accounting.state.sessionUploadBytes, 175);
      expect(accounting.state.sessionDownloadBytes, 295);
    },
  );

  test(
    'durable native cursor counts only traffic added while Flutter was stopped',
    () async {
      const token = 'durable-native-cursor-account';
      final first = _trafficContainer(_RecordingTrafficCocoApi());
      final firstAccounting = first.read(trafficAccountingProvider.notifier);
      first.read(tokenProvider.notifier).state = token;
      await Future<void>.delayed(Duration.zero);
      final firstVpn =
          first.read(vpnControllerProvider.notifier) as _TestVpnController;
      firstVpn.emitConnected();
      await Future<void>.delayed(Duration.zero);
      VpnChannel().report(
        VpnStatusEvent(
          stage: VpnStage.connected,
          sessionId: 'persistent-native-session',
          uploadBytesTotal: 100,
          downloadBytesTotal: 200,
        ),
      );
      await _waitUntil(() => firstAccounting.state.pendingBytes == 300);
      first.dispose();
      await Future<void>.delayed(Duration.zero);

      final second = _trafficContainer(_RecordingTrafficCocoApi());
      addTearDown(second.dispose);
      final secondAccounting = second.read(trafficAccountingProvider.notifier);
      second.read(tokenProvider.notifier).state = token;
      await _waitUntil(() => secondAccounting.state.pendingBytes == 300);
      final secondVpn =
          second.read(vpnControllerProvider.notifier) as _TestVpnController;
      secondVpn.emitConnected();
      await Future<void>.delayed(Duration.zero);

      // These totals include 110 bytes transferred while Runner was absent.
      // The first 300 bytes remain pending but must not be counted a second time.
      VpnChannel().report(
        VpnStatusEvent(
          stage: VpnStage.connected,
          sessionId: 'persistent-native-session',
          uploadBytesTotal: 150,
          downloadBytesTotal: 260,
        ),
      );
      await _waitUntil(() => secondAccounting.state.pendingBytes == 410);

      final state = secondAccounting.state;
      expect(state.sessionUploadBytes, 50);
      expect(state.sessionDownloadBytes, 60);
      expect(state.pendingBytes, 410);
    },
  );

  test(
    '402 heartbeat applies authoritative traffic and disconnects without clearing token',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final api = _QuotaExhaustedCocoApi();
      final repository = _TestSubscriptionRepository(_activeSubscription);
      final container = ProviderContainer(
        overrides: [
          cocoApiProvider.overrideWithValue(api),
          subscriptionRepositoryProvider.overrideWithValue(repository),
          vpnControllerProvider.overrideWith((ref) => _TestVpnController(ref)),
        ],
      );
      addTearDown(container.dispose);

      await container.read(subscriptionControllerProvider.notifier).fetch();
      container.read(trafficAccountingProvider);
      final vpn =
          container.read(vpnControllerProvider.notifier) as _TestVpnController;

      const token = 'active-session-token';
      container.read(tokenProvider.notifier).state = token;
      await Future<void>.delayed(Duration.zero);
      vpn.emitConnected();
      await Future<void>.delayed(Duration.zero);
      await container.read(trafficAccountingProvider.notifier).heartbeat();
      await _waitUntil(
        () =>
            container.read(trafficAccountingProvider).restriction ==
            CocoTrafficRestriction.quotaOrExpired,
      );

      final subscription =
          container.read(subscriptionControllerProvider) as SubscriptionReady;
      expect(subscription.status.trafficUsed, 4096);
      expect(subscription.status.trafficTotal, 4096);
      expect(subscription.status.canUse, isFalse);
      expect(container.read(vpnAccessProvider), isFalse);
      expect(vpn.forceDisconnectCalls, 1);
      expect(container.read(tokenProvider), token);

      final traffic = container.read(trafficAccountingProvider);
      expect(traffic.restriction, CocoTrafficRestriction.quotaOrExpired);
      expect(traffic.notice, isNotNull);
      expect(traffic.notice, isNotEmpty);
      expect(api.reportedBytes, [0]);
    },
  );

  test('positive flush sends a stable report id', () async {
    final api = _RecordingTrafficCocoApi();
    final container = _trafficContainer(api);
    addTearDown(container.dispose);
    final accounting = container.read(trafficAccountingProvider.notifier);
    final vpn =
        container.read(vpnControllerProvider.notifier) as _TestVpnController;

    container.read(tokenProvider.notifier).state = 'traffic-account';
    await Future<void>.delayed(Duration.zero);
    vpn.emitConnected();
    await Future<void>.delayed(Duration.zero);
    _reportNativeTraffic(upload: 120, download: 345);
    await Future<void>.delayed(Duration.zero);

    expect(await accounting.flush(), isTrue);

    final calls = api.positiveCalls;
    expect(calls, hasLength(1));
    expect(calls.single.bytes, 465);
    expect(calls.single.reportId, isNotEmpty);
    expect(
      calls.single.reportId,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          caseSensitive: false,
        ),
      ),
    );
    expect(accounting.state.pendingBytes, 0);
  });

  test(
    'a signed-in disconnected client does not send zero-byte polls',
    () async {
      final api = _RecordingTrafficCocoApi();
      final container = _trafficContainer(api);
      addTearDown(container.dispose);
      container.read(trafficAccountingProvider);

      container.read(tokenProvider.notifier).state = 'idle-account';
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(api.zeroCalls, 0);
      expect(api.positiveCalls, isEmpty);
    },
  );

  test(
    'repeated foreground events share the five-minute account window',
    () async {
      final api = _RecordingTrafficCocoApi();
      final container = ProviderContainer(
        overrides: [
          cocoApiProvider.overrideWithValue(api),
          vpnAccessProvider.overrideWithValue(true),
          vpnControllerProvider.overrideWith((ref) => _TestVpnController(ref)),
          subscriptionNodesLastRefreshProvider.overrideWith(
            (ref) => DateTime.now(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final accounting = container.read(trafficAccountingProvider.notifier);
      container.read(tokenProvider.notifier).state = 'resume-account';
      await Future<void>.delayed(Duration.zero);

      await accounting.resumeFromBackground();
      await accounting.resumeFromBackground();

      expect(api.zeroCalls, 1);
      expect(api.positiveCalls, isEmpty);
    },
  );

  test('failed foreground account sync is also rate limited', () async {
    final api = _RecordingTrafficCocoApi(failEveryZero: true);
    final container = ProviderContainer(
      overrides: [
        cocoApiProvider.overrideWithValue(api),
        vpnAccessProvider.overrideWithValue(true),
        vpnControllerProvider.overrideWith((ref) => _TestVpnController(ref)),
        subscriptionNodesLastRefreshProvider.overrideWith(
          (ref) => DateTime.now(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final accounting = container.read(trafficAccountingProvider.notifier);
    container.read(tokenProvider.notifier).state = 'failed-resume-account';
    await Future<void>.delayed(Duration.zero);

    await accounting.resumeFromBackground();
    await accounting.resumeFromBackground();

    expect(api.zeroCalls, 1);
  });

  test('a connected account sync sends one zero-byte request', () async {
    final api = _RecordingTrafficCocoApi();
    final container = _trafficContainer(api);
    addTearDown(container.dispose);
    final accounting = container.read(trafficAccountingProvider.notifier);
    final vpn =
        container.read(vpnControllerProvider.notifier) as _TestVpnController;

    container.read(tokenProvider.notifier).state = 'connected-account';
    await Future<void>.delayed(Duration.zero);
    vpn.emitConnected();
    await Future<void>.delayed(Duration.zero);
    expect(container.read(tokenProvider), 'connected-account');
    expect(accounting.state.connected, isTrue);
    await accounting.heartbeat();

    expect(api.zeroCalls, 1);
    expect(api.positiveCalls, isEmpty);
  });

  test('a five-minute sync keeps a small not-due batch local', () async {
    final api = _RecordingTrafficCocoApi();
    final container = _trafficContainer(api);
    addTearDown(container.dispose);
    final accounting = container.read(trafficAccountingProvider.notifier);
    final vpn =
        container.read(vpnControllerProvider.notifier) as _TestVpnController;

    container.read(tokenProvider.notifier).state = 'small-batch-account';
    await Future<void>.delayed(Duration.zero);
    vpn.emitConnected();
    await Future<void>.delayed(Duration.zero);
    _reportNativeTraffic(upload: 120, download: 345);
    await Future<void>.delayed(Duration.zero);
    await accounting.heartbeat();

    expect(api.zeroCalls, 1);
    expect(api.positiveCalls, isEmpty);
    expect(accounting.state.pendingBytes, 465);
  });

  test('pausing checkpoints a small batch without reporting it', () async {
    final api = _RecordingTrafficCocoApi();
    final container = _trafficContainer(api);
    addTearDown(container.dispose);
    final accounting = container.read(trafficAccountingProvider.notifier);
    final vpn =
        container.read(vpnControllerProvider.notifier) as _TestVpnController;
    final preferences = await SharedPreferences.getInstance();
    container.read(tokenProvider.notifier).state = 'paused-small-account';
    await Future<void>.delayed(Duration.zero);
    vpn.emitConnected();
    await Future<void>.delayed(Duration.zero);
    _reportNativeTraffic(upload: 120, download: 345);
    await Future<void>.delayed(Duration.zero);

    accounting.didChangeAppLifecycleState(AppLifecycleState.paused);
    await _waitUntil(() => preferences.getKeys().isNotEmpty);

    expect(api.positiveCalls, isEmpty);
    expect(accounting.state.pendingBytes, 465);
  });

  test('a successful positive flush suppresses a trailing zero poll', () async {
    final api = _RecordingTrafficCocoApi();
    final container = _trafficContainer(api);
    addTearDown(container.dispose);
    final accounting = container.read(trafficAccountingProvider.notifier);
    final vpn =
        container.read(vpnControllerProvider.notifier) as _TestVpnController;

    container.read(tokenProvider.notifier).state = 'pending-account';
    await Future<void>.delayed(Duration.zero);
    vpn.emitConnected();
    await Future<void>.delayed(Duration.zero);
    _reportNativeTraffic(upload: 120, download: 345);
    await Future<void>.delayed(Duration.zero);
    expect(await accounting.flush(), isTrue);
    await accounting.heartbeat();

    expect(api.positiveCalls, hasLength(1));
    expect(api.positiveCalls.single.bytes, 465);
    expect(api.zeroCalls, 0);
  });

  test(
    'a checkpointed batch absorbs later bytes into one positive report',
    () async {
      final api = _RecordingTrafficCocoApi();
      final container = ProviderContainer(
        overrides: [
          cocoApiProvider.overrideWithValue(api),
          vpnAccessProvider.overrideWithValue(true),
          vpnControllerProvider.overrideWith((ref) => _TestVpnController(ref)),
          trafficBatchCheckIntervalProvider.overrideWithValue(
            const Duration(milliseconds: 10),
          ),
        ],
      );
      addTearDown(container.dispose);
      final accounting = container.read(trafficAccountingProvider.notifier);
      final vpn =
          container.read(vpnControllerProvider.notifier) as _TestVpnController;
      final preferences = await SharedPreferences.getInstance();

      container.read(tokenProvider.notifier).state = 'combined-batch-account';
      await Future<void>.delayed(Duration.zero);
      vpn.emitConnected();
      await Future<void>.delayed(Duration.zero);
      _reportNativeTraffic(upload: 100, download: 200);
      await _waitUntil(() => preferences.getKeys().isNotEmpty);
      _reportNativeTraffic(upload: 150, download: 260);
      await Future<void>.delayed(Duration.zero);

      expect(await accounting.flush(), isTrue);
      expect(api.positiveCalls, hasLength(1));
      expect(api.positiveCalls.single.bytes, 410);
    },
  );

  test(
    'slow positive reporting is single-flight while traffic continues',
    () async {
      final api = _RecordingTrafficCocoApi(blockPositive: true);
      final container = ProviderContainer(
        overrides: [
          cocoApiProvider.overrideWithValue(api),
          vpnAccessProvider.overrideWithValue(true),
          vpnControllerProvider.overrideWith((ref) => _TestVpnController(ref)),
          trafficBatchCheckIntervalProvider.overrideWithValue(
            const Duration(milliseconds: 10),
          ),
        ],
      );
      addTearDown(container.dispose);
      final accounting = container.read(trafficAccountingProvider.notifier);
      final vpn =
          container.read(vpnControllerProvider.notifier) as _TestVpnController;
      container.read(tokenProvider.notifier).state = 'slow-positive-account';
      await Future<void>.delayed(Duration.zero);
      vpn.emitConnected();
      await Future<void>.delayed(Duration.zero);

      _reportNativeTraffic(
        upload: TrafficAccountingController.reportThresholdBytes,
        download: 0,
      );
      await _waitUntil(() => api.positiveCalls.length == 1);
      _reportNativeTraffic(
        upload: TrafficAccountingController.reportThresholdBytes + 1000,
        download: 0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(api.positiveCalls, hasLength(1));

      api.releasePositive();
      await _waitUntil(() => !accounting.state.syncing);
      expect(api.positiveCalls, hasLength(1));
      expect(accounting.state.pendingBytes, 1000);
    },
  );

  test('automatic positive retries observe the backoff window', () async {
    final api = _RecordingTrafficCocoApi(failEveryPositive: true);
    final container = ProviderContainer(
      overrides: [
        cocoApiProvider.overrideWithValue(api),
        vpnAccessProvider.overrideWithValue(true),
        vpnControllerProvider.overrideWith((ref) => _TestVpnController(ref)),
        trafficBatchCheckIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 5),
        ),
        trafficRetryBackoffProvider.overrideWithValue(
          const Duration(milliseconds: 60),
        ),
      ],
    );
    addTearDown(container.dispose);
    final vpn =
        container.read(vpnControllerProvider.notifier) as _TestVpnController;
    container.read(trafficAccountingProvider);
    container.read(tokenProvider.notifier).state = 'backoff-account';
    await Future<void>.delayed(Duration.zero);
    vpn.emitConnected();
    await Future<void>.delayed(Duration.zero);

    _reportNativeTraffic(
      upload: TrafficAccountingController.reportThresholdBytes,
      download: 0,
    );
    await _waitUntil(() => api.positiveCalls.length == 1);
    for (var index = 1; index <= 4; index++) {
      _reportNativeTraffic(
        upload: TrafficAccountingController.reportThresholdBytes + index,
        download: 0,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(api.positiveCalls, hasLength(1));

    await _waitUntil(() => api.positiveCalls.length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(api.positiveCalls, hasLength(2));
  });

  test(
    'a disconnected failed batch is not retried by the batch timer',
    () async {
      final api = _RecordingTrafficCocoApi(failEveryPositive: true);
      final container = ProviderContainer(
        overrides: [
          cocoApiProvider.overrideWithValue(api),
          vpnAccessProvider.overrideWithValue(true),
          vpnControllerProvider.overrideWith((ref) => _TestVpnController(ref)),
          trafficBatchCheckIntervalProvider.overrideWithValue(
            const Duration(milliseconds: 10),
          ),
        ],
      );
      addTearDown(container.dispose);
      final accounting = container.read(trafficAccountingProvider.notifier);
      final vpn =
          container.read(vpnControllerProvider.notifier) as _TestVpnController;

      container.read(tokenProvider.notifier).state = 'offline-retry-account';
      await Future<void>.delayed(Duration.zero);
      vpn.emitConnected();
      await Future<void>.delayed(Duration.zero);
      _reportNativeTraffic(upload: 100, download: 200);
      await Future<void>.delayed(Duration.zero);
      expect(await accounting.flush(), isFalse);
      vpn.emitIdle();
      await _waitUntil(() => api.positiveCalls.length >= 2);
      final callsAfterDisconnect = api.positiveCalls.length;

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(api.positiveCalls, hasLength(callsAfterDisconnect));
      expect(accounting.state.connected, isFalse);
    },
  );

  test(
    'a late account snapshot cannot replace fresher subscription metadata',
    () async {
      final api = _DelayedAccountCocoApi();
      final repository = _TestSubscriptionRepository(_activeSubscription);
      final container = ProviderContainer(
        overrides: [
          cocoApiProvider.overrideWithValue(api),
          subscriptionRepositoryProvider.overrideWithValue(repository),
          vpnAccessProvider.overrideWithValue(true),
          vpnControllerProvider.overrideWith((ref) => _TestVpnController(ref)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(subscriptionControllerProvider.notifier).fetch();
      final accounting = container.read(trafficAccountingProvider.notifier);
      final vpn =
          container.read(vpnControllerProvider.notifier) as _TestVpnController;
      container.read(tokenProvider.notifier).state = 'metadata-race-account';
      await Future<void>.delayed(Duration.zero);
      vpn.emitConnected();
      await Future<void>.delayed(Duration.zero);

      final sync = accounting.heartbeat();
      await api.started.future;
      repository.cached = _activeSubscription.copyWith(
        paidUntil: '2035-01-01T00:00:00Z',
        trafficTotal: 16384,
        trafficUsed: 1200,
        level: 2,
        updatedAt: '2035-01-01T00:00:00Z',
      );
      await container
          .read(subscriptionControllerProvider.notifier)
          .fetch(forceRefresh: true);
      api.release();
      await sync;

      final subscription =
          container.read(subscriptionControllerProvider) as SubscriptionReady;
      expect(subscription.status.subUrl, _activeSubscription.subUrl);
      expect(subscription.status.paidUntil, '2035-01-01T00:00:00Z');
      expect(subscription.status.trafficTotal, 16384);
      expect(subscription.status.trafficUsed, 1200);
      expect(subscription.status.level, 2);
    },
  );

  test(
    'a stale quota response cannot disconnect a freshly renewed account',
    () async {
      final api = _DelayedAccountCocoApi(restricted: true);
      final repository = _TestSubscriptionRepository(_activeSubscription);
      final container = ProviderContainer(
        overrides: [
          cocoApiProvider.overrideWithValue(api),
          subscriptionRepositoryProvider.overrideWithValue(repository),
          vpnAccessProvider.overrideWithValue(true),
          vpnControllerProvider.overrideWith((ref) => _TestVpnController(ref)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(subscriptionControllerProvider.notifier).fetch();
      final accounting = container.read(trafficAccountingProvider.notifier);
      final vpn =
          container.read(vpnControllerProvider.notifier) as _TestVpnController;
      container.read(tokenProvider.notifier).state = 'renewal-race-account';
      await Future<void>.delayed(Duration.zero);
      vpn.emitConnected();
      await Future<void>.delayed(Duration.zero);

      final sync = accounting.heartbeat();
      await api.started.future;
      repository.cached = _activeSubscription.copyWith(
        paidUntil: '2035-01-01T00:00:00Z',
        trafficTotal: 16384,
        trafficUsed: 0,
        updatedAt: '2035-01-01T00:00:00Z',
      );
      await container
          .read(subscriptionControllerProvider.notifier)
          .fetch(forceRefresh: true);
      api.release();
      await sync;

      final subscription =
          container.read(subscriptionControllerProvider) as SubscriptionReady;
      expect(subscription.status.canUse, isTrue);
      expect(subscription.status.trafficTotal, 16384);
      expect(accounting.state.restriction, isNull);
      expect(vpn.forceDisconnectCalls, 0);
    },
  );

  test('a newer disabled snapshot overrides changed local metadata', () async {
    final api = _DelayedAccountCocoApi(
      restricted: true,
      accountUpdatedAt: DateTime.utc(2036),
      restriction: CocoTrafficRestriction.accountDisabled,
    );
    final repository = _TestSubscriptionRepository(_activeSubscription);
    final container = ProviderContainer(
      overrides: [
        cocoApiProvider.overrideWithValue(api),
        subscriptionRepositoryProvider.overrideWithValue(repository),
        connectivityChangesProvider.overrideWith(
          (ref) => Stream<OnlineStatus>.value(OnlineStatus.online),
        ),
        vpnAccessProvider.overrideWithValue(true),
        vpnControllerProvider.overrideWith((ref) => _TestVpnController(ref)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(subscriptionControllerProvider.notifier).fetch();
    final accounting = container.read(trafficAccountingProvider.notifier);
    final vpn =
        container.read(vpnControllerProvider.notifier) as _TestVpnController;
    container.read(tokenProvider.notifier).state = 'disabled-race-account';
    await Future<void>.delayed(Duration.zero);
    vpn.emitConnected();
    await Future<void>.delayed(Duration.zero);

    final sync = accounting.heartbeat();
    await api.started.future;
    repository.cached = _activeSubscription.copyWith(
      trafficUsed: 1200,
      updatedAt: '2035-01-01T00:00:00Z',
    );
    await container
        .read(subscriptionControllerProvider.notifier)
        .fetch(forceRefresh: true);
    api.release();
    await sync;

    expect(vpn.forceDisconnectCalls, 1);
    expect(container.read(tokenProvider), isNull);
  });

  test(
    'failed flush retries the same report id without double counting pending',
    () async {
      final api = _RecordingTrafficCocoApi(failFirstPositive: true);
      final container = _trafficContainer(api);
      addTearDown(container.dispose);
      final accounting = container.read(trafficAccountingProvider.notifier);
      final vpn =
          container.read(vpnControllerProvider.notifier) as _TestVpnController;

      container.read(tokenProvider.notifier).state = 'retry-account';
      await Future<void>.delayed(Duration.zero);
      vpn.emitConnected();
      await Future<void>.delayed(Duration.zero);
      _reportNativeTraffic(upload: 100, download: 200);
      await Future<void>.delayed(Duration.zero);

      expect(accounting.state.pendingBytes, 300);
      expect(await accounting.flush(), isFalse);
      expect(accounting.state.pendingBytes, 300);
      expect(api.positiveCalls, hasLength(1));

      final first = api.positiveCalls.single;
      expect(await accounting.flush(), isTrue);

      expect(api.positiveCalls, hasLength(2));
      final second = api.positiveCalls.last;
      expect(second.bytes, first.bytes);
      expect(second.reportId, first.reportId);
      expect(accounting.state.pendingBytes, 0);
    },
  );

  test('explicit flush drains a retry and later traffic in order', () async {
    final api = _RecordingTrafficCocoApi(failFirstPositive: true);
    final container = _trafficContainer(api);
    addTearDown(container.dispose);
    final accounting = container.read(trafficAccountingProvider.notifier);
    final vpn =
        container.read(vpnControllerProvider.notifier) as _TestVpnController;

    container.read(tokenProvider.notifier).state = 'ordered-retry-account';
    await Future<void>.delayed(Duration.zero);
    vpn.emitConnected();
    await Future<void>.delayed(Duration.zero);
    _reportNativeTraffic(upload: 100, download: 200);
    await Future<void>.delayed(Duration.zero);
    expect(await accounting.flush(), isFalse);
    _reportNativeTraffic(upload: 150, download: 260);
    await Future<void>.delayed(Duration.zero);

    expect(await accounting.flush(), isTrue);
    expect(api.positiveCalls, hasLength(3));
    expect(api.positiveCalls[1].reportId, api.positiveCalls[0].reportId);
    expect(api.positiveCalls[1].bytes, 300);
    expect(api.positiveCalls[2].reportId, isNot(api.positiveCalls[0].reportId));
    expect(api.positiveCalls[2].bytes, 110);
    expect(accounting.state.pendingBytes, 0);
  });

  test('queued traffic survives restart behind an uncertain retry', () async {
    const token = 'queued-restart-account';
    final failingApi = _RecordingTrafficCocoApi(failEveryPositive: true);
    final firstContainer = _trafficContainer(failingApi);
    final accounting = firstContainer.read(trafficAccountingProvider.notifier);
    final vpn =
        firstContainer.read(vpnControllerProvider.notifier)
            as _TestVpnController;
    firstContainer.read(tokenProvider.notifier).state = token;
    await Future<void>.delayed(Duration.zero);
    vpn.emitConnected();
    await Future<void>.delayed(Duration.zero);
    _reportNativeTraffic(upload: 100, download: 200);
    await Future<void>.delayed(Duration.zero);
    expect(await accounting.flush(), isFalse);
    final failedCall = failingApi.positiveCalls.single;
    _reportNativeTraffic(upload: 150, download: 260);
    await Future<void>.delayed(Duration.zero);

    accounting.didChangeAppLifecycleState(AppLifecycleState.paused);
    final preferences = await SharedPreferences.getInstance();
    await _waitUntil(() {
      final raw = preferences.getString(_pendingKey(token));
      final data = raw == null ? null : jsonDecode(raw);
      return data is Map &&
          data['batches'] is List &&
          data['batches'].length == 2;
    });
    expect(accounting.state.pendingBytes, 410);
    firstContainer.dispose();
    await Future<void>.delayed(Duration.zero);

    final retryApi = _RecordingTrafficCocoApi();
    final secondContainer = _trafficContainer(retryApi);
    addTearDown(secondContainer.dispose);
    final restored = secondContainer.read(trafficAccountingProvider.notifier);
    secondContainer.read(tokenProvider.notifier).state = token;
    await _waitUntil(
      () =>
          retryApi.positiveCalls.length == 2 &&
          restored.state.pendingBytes == 0,
    );

    expect(retryApi.positiveCalls[0].reportId, failedCall.reportId);
    expect(retryApi.positiveCalls[0].bytes, 300);
    expect(retryApi.positiveCalls[1].reportId, isNot(failedCall.reportId));
    expect(retryApi.positiveCalls[1].bytes, 110);
    expect(
      retryApi.positiveCalls.fold<int>(0, (sum, call) => sum + call.bytes),
      410,
    );
  });

  test(
    'provider rebuild restores pending batch and reuses its report id',
    () async {
      const token = 'restored-account';
      final failingApi = _RecordingTrafficCocoApi(failFirstPositive: true);
      final firstContainer = _trafficContainer(failingApi);
      final firstAccounting = firstContainer.read(
        trafficAccountingProvider.notifier,
      );
      final firstVpn =
          firstContainer.read(vpnControllerProvider.notifier)
              as _TestVpnController;

      firstContainer.read(tokenProvider.notifier).state = token;
      await Future<void>.delayed(Duration.zero);
      firstVpn.emitConnected();
      await Future<void>.delayed(Duration.zero);
      _reportNativeTraffic(upload: 256, download: 512);
      await Future<void>.delayed(Duration.zero);
      expect(await firstAccounting.flush(), isFalse);
      final persistedCall = failingApi.positiveCalls.single;
      expect(firstAccounting.state.pendingBytes, 768);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getKeys(), isNotEmpty);
      firstContainer.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(preferences.getKeys(), isNotEmpty);

      final retryApi = _RecordingTrafficCocoApi(blockPositive: true);
      final secondContainer = _trafficContainer(retryApi);
      addTearDown(secondContainer.dispose);
      final restoredAccounting = secondContainer.read(
        trafficAccountingProvider.notifier,
      );
      secondContainer.read(tokenProvider.notifier).state = token;

      await _waitUntil(() => retryApi.positiveCalls.isNotEmpty);
      expect(retryApi.positiveCalls, hasLength(1));
      expect(retryApi.positiveCalls.single.bytes, persistedCall.bytes);
      expect(retryApi.positiveCalls.single.reportId, persistedCall.reportId);
      expect(restoredAccounting.state.pendingBytes, persistedCall.bytes);

      retryApi.releasePositive();
      await _waitUntil(() => restoredAccounting.state.pendingBytes == 0);
      expect(restoredAccounting.state.pendingBytes, 0);
      final raw = (await SharedPreferences.getInstance()).getString(
        _pendingKey(token),
      );
      final ledger = jsonDecode(raw!) as Map;
      expect(ledger['batches'], isEmpty);
      expect(ledger['pending_bytes'], 0);
      expect(ledger['native_cursor'], isNotNull);
    },
  );
}

String _pendingKey(String token) =>
    'traffic.pending.v1.${sha256.convert(utf8.encode(token))}';

ProviderContainer _trafficContainer(CocoApi api) {
  return ProviderContainer(
    overrides: [
      cocoApiProvider.overrideWithValue(api),
      vpnAccessProvider.overrideWithValue(true),
      vpnControllerProvider.overrideWith((ref) => _TestVpnController(ref)),
    ],
  );
}

void _reportNativeTraffic({required int upload, required int download}) {
  VpnChannel().report(
    VpnStatusEvent(
      stage: VpnStage.connected,
      sessionId: 'accounting-test-session',
      uploadBytesTotal: upload,
      downloadBytesTotal: download,
    ),
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for traffic state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

const _activeSubscription = SubscriptionStatus(
  isTrial: false,
  isPaid: true,
  paidUntil: '2030-01-01T00:00:00Z',
  canUse: true,
  deviceCount: 1,
  maxDevices: 3,
  balance: 0,
  subUrl: 'https://example.test/sub',
  trafficTotal: 8192,
  trafficUsed: 1024,
  level: 1,
  updatedAt: '2029-01-01T00:00:00Z',
);

class _TestVpnController extends VpnController {
  _TestVpnController(Ref ref)
    : super(
        connect: () async {},
        disconnect: () async {},
        isConnected: () async => false,
        ref: ref,
      );

  int forceDisconnectCalls = 0;

  void emitConnected() => state = const VpnConnected();

  void emitIdle() => state = const VpnIdle();

  @override
  Future<void> forceDisconnect() async {
    forceDisconnectCalls++;
    state = const VpnIdle();
  }
}

class _QuotaExhaustedCocoApi extends CocoApi {
  _QuotaExhaustedCocoApi() : super(_NeverApiService());

  final List<int> reportedBytes = [];

  @override
  Future<CocoTrafficReport> reportTraffic(
    int bytes, {
    String? reportId,
    CancelToken? cancelToken,
  }) async {
    reportedBytes.add(bytes);
    return const CocoTrafficReport(
      accepted: 0,
      trafficTotal: 4096,
      trafficUsed: 4096,
      trafficRemaining: 0,
      trafficLine: '4.00 KB / 4.00 KB',
      statusCode: 402,
      message: 'quota exhausted',
      restriction: CocoTrafficRestriction.quotaOrExpired,
      hasTrafficSnapshot: true,
    );
  }
}

class _TrafficCall {
  final int bytes;
  final String reportId;

  const _TrafficCall({required this.bytes, required this.reportId});
}

class _RecordingTrafficCocoApi extends CocoApi {
  _RecordingTrafficCocoApi({
    this.failFirstPositive = false,
    this.failEveryPositive = false,
    this.failEveryZero = false,
    bool blockPositive = false,
  }) : _positiveGate = blockPositive ? Completer<void>() : null,
       super(_NeverApiService());

  final bool failFirstPositive;
  final bool failEveryPositive;
  final bool failEveryZero;
  final Completer<void>? _positiveGate;
  final List<_TrafficCall> positiveCalls = [];
  int zeroCalls = 0;

  void releasePositive() => _positiveGate?.complete();

  @override
  Future<CocoTrafficReport> reportTraffic(
    int bytes, {
    String? reportId,
    CancelToken? cancelToken,
  }) async {
    if (bytes == 0) {
      zeroCalls++;
      if (failEveryZero) {
        throw DioException(
          requestOptions: RequestOptions(path: '/v1/traffic'),
          type: DioExceptionType.connectionError,
          message: 'simulated zero-byte failure',
        );
      }
      return _successReport(bytes: 0, reportId: reportId);
    }

    positiveCalls.add(_TrafficCall(bytes: bytes, reportId: reportId ?? ''));
    if (failEveryPositive || (failFirstPositive && positiveCalls.length == 1)) {
      throw DioException(
        requestOptions: RequestOptions(path: '/v1/traffic'),
        type: DioExceptionType.connectionError,
        message: 'simulated network failure',
      );
    }
    await _positiveGate?.future;
    return _successReport(bytes: bytes, reportId: reportId);
  }

  CocoTrafficReport _successReport({required int bytes, String? reportId}) {
    return CocoTrafficReport(
      accepted: bytes,
      trafficTotal: 1024 * 1024,
      trafficUsed: bytes,
      trafficRemaining: 1024 * 1024 - bytes,
      trafficLine: '',
      statusCode: 200,
      message: 'ok',
      restriction: null,
      reportId: reportId ?? '',
    );
  }
}

class _DelayedAccountCocoApi extends CocoApi {
  _DelayedAccountCocoApi({
    this.restricted = false,
    DateTime? accountUpdatedAt,
    this.restriction = CocoTrafficRestriction.quotaOrExpired,
  }) : accountUpdatedAt = accountUpdatedAt ?? DateTime.utc(2029),
       super(_NeverApiService());

  final bool restricted;
  final DateTime accountUpdatedAt;
  final CocoTrafficRestriction restriction;

  final started = Completer<void>();
  final _release = Completer<void>();

  void release() => _release.complete();

  @override
  Future<CocoTrafficReport> reportTraffic(
    int bytes, {
    String? reportId,
    CancelToken? cancelToken,
  }) async {
    started.complete();
    await _release.future;
    final used = restricted ? 8192 : 2048;
    return CocoTrafficReport(
      accepted: 0,
      trafficTotal: 8192,
      trafficUsed: used,
      trafficRemaining: 8192 - used,
      trafficLine: '',
      statusCode: restricted
          ? restriction == CocoTrafficRestriction.accountDisabled
                ? 403
                : 402
          : 200,
      message: restricted ? 'quota exhausted' : 'ok',
      restriction: restricted ? restriction : null,
      hasTrafficSnapshot: true,
      account: CocoTrafficAccount(
        status: 1,
        expiresAt: DateTime.utc(2030),
        subscriptionUrl: _activeSubscription.subUrl,
        updatedAt: accountUpdatedAt,
        trafficTotal: 8192,
        trafficUsed: used,
      ),
    );
  }
}

class _TestSubscriptionRepository implements SubscriptionRepository {
  _TestSubscriptionRepository(this._cached);

  SubscriptionStatus? _cached;

  set cached(SubscriptionStatus value) => _cached = value;

  @override
  SubscriptionStatus? getCached() => _cached;

  @override
  bool isCacheFresh() => true;

  @override
  Future<SubscriptionStatus> fetchFresh({CancelToken? cancelToken}) async =>
      _cached!;

  @override
  Future<SubscriptionStatus?> applyTrafficSnapshot({
    required int total,
    required int used,
    bool? canUse,
    String? paidUntil,
    String? subUrl,
    String? updatedAt,
  }) async {
    _cached = _cached?.copyWith(
      trafficTotal: total,
      trafficUsed: used,
      canUse: canUse,
      paidUntil: paidUntil,
      subUrl: subUrl,
      updatedAt: updatedAt,
    );
    return _cached;
  }

  @override
  Future<SubscriptionStatus?> markBlocked() async {
    _cached = _cached?.copyWith(canUse: false);
    return _cached;
  }

  @override
  Future<void> clearCache() async {
    _cached = null;
  }
}

class _NeverApiService extends ApiService {
  _NeverApiService() : super(Dio());
}
