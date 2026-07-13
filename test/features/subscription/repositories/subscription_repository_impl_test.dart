import 'package:dio/dio.dart';
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
}

class _UserInfoApiService extends ApiService {
  _UserInfoApiService() : super(Dio());

  @override
  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? query,
    Options? options,
    CancelToken? cancelToken,
  }) async {
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
