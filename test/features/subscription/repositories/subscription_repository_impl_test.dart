import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpn_app/core/api/api_service.dart';
import 'package:vpn_app/core/cache/disk_cache.dart';
import 'package:vpn_app/core/cache/swr/swr_keys.dart';
import 'package:vpn_app/core/cache/swr/swr_store.dart';
import 'package:vpn_app/features/subscription/repositories/subscription_repository_impl.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'traffic snapshots update SWR and disk while preserving account data',
    () async {
      final swr = SwrStore();
      addTearDown(swr.dispose);
      final repository = SubscriptionRepositoryImpl(
        _UserInfoApiService(),
        ttl: const Duration(minutes: 5),
        swr: swr,
      );
      final original = await repository.fetchFresh();

      final updated = await repository.applyTrafficSnapshot(
        total: 2000,
        used: 750,
      );

      expect(updated, isNotNull);
      expect(updated!.trafficTotal, 2000);
      expect(updated.trafficUsed, 750);
      expect(updated.canUse, original.canUse);
      expect(updated.balance, original.balance);
      expect(updated.subUrl, original.subUrl);
      expect(repository.getCached(), same(updated));

      final snapshot = await DiskCache.getJson<Map>(
        SwrKeys.subscription,
        ttl: const Duration(minutes: 5),
      );
      expect(snapshot?['traffic_total'], 2000);
      expect(snapshot?['traffic_used'], 750);
      expect(snapshot?['balance'], original.balance);
    },
  );

  test(
    'markBlocked preserves traffic and clearCache removes both cache views',
    () async {
      final swr = SwrStore();
      addTearDown(swr.dispose);
      final repository = SubscriptionRepositoryImpl(
        _UserInfoApiService(),
        ttl: const Duration(minutes: 5),
        swr: swr,
      );
      await repository.fetchFresh();
      await repository.applyTrafficSnapshot(total: 5000, used: 1234);

      final blocked = await repository.markBlocked();

      expect(blocked, isNotNull);
      expect(blocked!.canUse, isFalse);
      expect(blocked.trafficTotal, 5000);
      expect(blocked.trafficUsed, 1234);

      await repository.clearCache();

      expect(repository.getCached(), isNull);
      expect(repository.isCacheFresh(), isFalse);
      expect(
        await DiskCache.getJson<Map>(
          SwrKeys.subscription,
          ttl: const Duration(minutes: 5),
        ),
        isNull,
      );
    },
  );

  test('in-flight fresh metadata survives a newer traffic snapshot', () async {
    final swr = SwrStore();
    addTearDown(swr.dispose);
    final api = _DelayedUserInfoApiService();
    final repository = SubscriptionRepositoryImpl(
      api,
      ttl: const Duration(minutes: 5),
      swr: swr,
    );
    await repository.fetchFresh();

    final pendingFresh = repository.fetchFresh();
    await api.secondRequestStarted.future;
    await repository.applyTrafficSnapshot(total: 1000, used: 900);
    api.releaseSecondRequest();
    final merged = await pendingFresh;

    expect(merged.subUrl, 'https://example.test/new-sub');
    expect(merged.paidUntil, '2035-01-01T00:00:00.000Z');
    expect(merged.trafficTotal, 2000);
    expect(merged.trafficUsed, 900);
    expect(merged.canUse, isTrue);
    expect(repository.getCached(), same(merged));
  });

  test(
    'an older in-flight userinfo cannot replace a newer account revision',
    () async {
      final swr = SwrStore();
      addTearDown(swr.dispose);
      final api = _DelayedUserInfoApiService();
      final repository = SubscriptionRepositoryImpl(
        api,
        ttl: const Duration(minutes: 5),
        swr: swr,
      );
      await repository.fetchFresh();

      final pendingFresh = repository.fetchFresh();
      await api.secondRequestStarted.future;
      await repository.applyTrafficSnapshot(
        total: 3000,
        used: 900,
        paidUntil: '2036-01-01T00:00:00Z',
        subUrl: 'https://example.test/newer-account-sub',
        updatedAt: '2036-01-01T00:00:00Z',
      );
      api.releaseSecondRequest();
      final result = await pendingFresh;

      expect(result.subUrl, 'https://example.test/newer-account-sub');
      expect(result.paidUntil, '2036-01-01T00:00:00Z');
      expect(result.trafficTotal, 3000);
      expect(result.trafficUsed, 900);
      expect(result.updatedAt, '2036-01-01T00:00:00Z');
    },
  );

  test(
    'subscription SWR does not duplicate the centralized resume sync',
    () async {
      final swr = SwrStore();
      addTearDown(swr.dispose);
      final api = _UserInfoApiService();
      final repository = SubscriptionRepositoryImpl(
        api,
        ttl: Duration.zero,
        swr: swr,
      );
      await repository.fetchFresh();

      swr.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(api.calls, 1);
    },
  );
}

class _UserInfoApiService extends ApiService {
  _UserInfoApiService() : super(Dio());

  int calls = 0;

  @override
  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? query,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    calls++;
    final data = <String, dynamic>{
      'code': 200,
      'info': 'success',
      'data': {
        'username': 'traffic-user',
        'true_name': 'traffic@example.test',
        'balance': 12.5,
        'class': 2,
        'class_expire': '2030-01-01T00:00:00Z',
        'proxy_available': true,
        'profile_url': 'https://example.test/sub',
        'traffic': {'total': 1000, 'used': 100},
      },
    };
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data as T,
    );
  }
}

class _DelayedUserInfoApiService extends ApiService {
  _DelayedUserInfoApiService() : super(Dio());

  final secondRequestStarted = Completer<void>();
  final _releaseSecondRequest = Completer<void>();
  int _calls = 0;

  void releaseSecondRequest() => _releaseSecondRequest.complete();

  @override
  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? query,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    _calls++;
    if (_calls > 1) {
      secondRequestStarted.complete();
      await _releaseSecondRequest.future;
    }
    final fresh = _calls > 1;
    final data = <String, dynamic>{
      'code': 200,
      'info': 'success',
      'data': {
        'username': 'race-user',
        'true_name': 'race@example.test',
        'balance': 12.5,
        'class': 2,
        'class_expire': fresh ? '2035-01-01T00:00:00Z' : '2030-01-01T00:00:00Z',
        'updated_at': fresh ? '2035-01-01T00:00:00Z' : '2029-01-01T00:00:00Z',
        'proxy_available': true,
        'profile_url': fresh
            ? 'https://example.test/new-sub'
            : 'https://example.test/old-sub',
        'traffic': {'total': fresh ? 2000 : 1000, 'used': fresh ? 200 : 100},
      },
    };
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data as T,
    );
  }
}
