import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/features/subscription/models/subscription_state.dart';
import 'package:vpn_app/features/subscription/models/subscription_status.dart';
import 'package:vpn_app/features/subscription/providers/subscription_controller.dart';
import 'package:vpn_app/features/subscription/repositories/subscription_repository.dart';

void main() {
  test(
    'copyWith updates traffic without dropping other subscription fields',
    () {
      final updated = _status.copyWith(trafficTotal: 9000, trafficUsed: 4500);

      expect(updated.trafficTotal, 9000);
      expect(updated.trafficUsed, 4500);
      expect(updated.canUse, isTrue);
      expect(updated.subUrl, _status.subUrl);
      expect(updated.balance, _status.balance);
    },
  );

  test(
    'controller applies snapshots, blocks access, and clears state',
    () async {
      final repository = _FakeSubscriptionRepository(_status);
      final controller = SubscriptionController(repository);
      addTearDown(controller.dispose);
      await controller.fetch();

      await controller.applyTrafficSnapshot(total: 9000, used: 4500);

      var ready = controller.state as SubscriptionReady;
      expect(ready.status.trafficTotal, 9000);
      expect(ready.status.trafficUsed, 4500);
      expect(ready.status.canUse, isTrue);

      await controller.markBlocked();

      ready = controller.state as SubscriptionReady;
      expect(ready.status.canUse, isFalse);
      expect(ready.status.trafficTotal, 9000);
      expect(ready.status.trafficUsed, 4500);

      await controller.clearCache();

      expect(controller.state, isA<SubscriptionIdle>());
      expect(repository.getCached(), isNull);
    },
  );

  test(
    'pending fresh fetch survives an early traffic snapshot and becomes ready',
    () async {
      final repository = _PendingFetchSubscriptionRepository();
      final controller = SubscriptionController(repository);
      addTearDown(controller.dispose);

      final fetch = controller.fetch(forceRefresh: true);

      expect(controller.state, isA<SubscriptionLoading>());
      expect(repository.fetchToken, isNotNull);

      await controller.applyTrafficSnapshot(total: 9000, used: 4500);

      expect(repository.fetchToken!.isCancelled, isFalse);
      expect(controller.state, isA<SubscriptionLoading>());

      repository.fresh.complete(_status);
      await fetch;

      final ready = controller.state as SubscriptionReady;
      expect(ready.status, same(_status));
    },
  );

  test('markBlocked does not cancel a pending fresh fetch', () async {
    final repository = _PendingFetchSubscriptionRepository();
    final controller = SubscriptionController(repository);
    addTearDown(controller.dispose);

    final fetch = controller.fetch(forceRefresh: true);
    await controller.markBlocked();

    expect(repository.fetchToken, isNotNull);
    expect(repository.fetchToken!.isCancelled, isFalse);

    repository.fresh.complete(_status);
    await fetch;

    expect(controller.state, isA<SubscriptionReady>());
  });
}

const _status = SubscriptionStatus(
  isTrial: false,
  isPaid: true,
  paidUntil: '2030-01-01T00:00:00Z',
  canUse: true,
  deviceCount: 1,
  maxDevices: 3,
  balance: 12.5,
  subUrl: 'https://example.test/sub',
  trafficTotal: 1000,
  trafficUsed: 100,
  level: 2,
);

class _FakeSubscriptionRepository implements SubscriptionRepository {
  _FakeSubscriptionRepository(this._cached);

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
    String? paidUntil,
    String? subUrl,
    String? updatedAt,
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

class _PendingFetchSubscriptionRepository implements SubscriptionRepository {
  final fresh = Completer<SubscriptionStatus>();
  CancelToken? fetchToken;

  @override
  SubscriptionStatus? getCached() => null;

  @override
  bool isCacheFresh() => false;

  @override
  Future<SubscriptionStatus> fetchFresh({CancelToken? cancelToken}) {
    fetchToken = cancelToken;
    return fresh.future;
  }

  @override
  Future<SubscriptionStatus?> applyTrafficSnapshot({
    required int total,
    required int used,
    bool? canUse,
    String? paidUntil,
    String? subUrl,
    String? updatedAt,
  }) async => null;

  @override
  Future<SubscriptionStatus?> markBlocked() async => null;

  @override
  Future<void> clearCache() async {}
}
