import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpn_app/core/api/api_service.dart';
import 'package:vpn_app/core/api/coco_api.dart';
import 'package:vpn_app/features/auth/providers/auth_providers.dart';
import 'package:vpn_app/features/subscription/models/subscription_state.dart';
import 'package:vpn_app/features/subscription/models/subscription_status.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/subscription/repositories/subscription_repository.dart';
import 'package:vpn_app/features/traffic/models/traffic_accounting_state.dart';
import 'package:vpn_app/features/traffic/providers/traffic_accounting_provider.dart';
import 'package:vpn_app/features/vpn/platform/vpn_channel.dart';
import 'package:vpn_app/features/vpn/providers/vpn_controller.dart';
import 'package:wireguard_flutter/wireguard_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
    expect(TrafficAccountingController.reportThresholdBytes, 20 * 1024 * 1024);
    expect(
      TrafficAccountingController.reportInterval,
      const Duration(minutes: 5),
    );
    expect(
      TrafficAccountingController.heartbeatInterval,
      const Duration(seconds: 30),
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
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );
}

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
    bool blockPositive = false,
  }) : _positiveGate = blockPositive ? Completer<void>() : null,
       super(_NeverApiService());

  final bool failFirstPositive;
  final Completer<void>? _positiveGate;
  final List<_TrafficCall> positiveCalls = [];

  void releasePositive() => _positiveGate?.complete();

  @override
  Future<CocoTrafficReport> reportTraffic(
    int bytes, {
    String? reportId,
    CancelToken? cancelToken,
  }) async {
    if (bytes == 0) return _successReport(bytes: 0, reportId: reportId);

    positiveCalls.add(_TrafficCall(bytes: bytes, reportId: reportId ?? ''));
    if (failFirstPositive && positiveCalls.length == 1) {
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

class _TestSubscriptionRepository implements SubscriptionRepository {
  _TestSubscriptionRepository(this._cached);

  SubscriptionStatus? _cached;

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
  }) async {
    _cached = _cached?.copyWith(
      trafficTotal: total,
      trafficUsed: used,
      canUse: canUse,
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
