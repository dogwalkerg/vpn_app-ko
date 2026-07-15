import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/api/api_service.dart';
import 'package:vpn_app/core/api/coco_api.dart';
import 'package:vpn_app/features/subscription/models/subscription_status.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/subscription/repositories/subscription_repository.dart';
import 'package:vpn_app/features/vpn/providers/subscription_nodes_provider.dart';

void main() {
  test(
    'traffic-only snapshots do not download the subscription again',
    () async {
      final api = _CountingSubscriptionApi();
      final repository = _SubscriptionRepository(_activeSubscription);
      final container = ProviderContainer(
        overrides: [
          cocoApiProvider.overrideWithValue(api),
          subscriptionRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(subscriptionControllerProvider.notifier)
          .fetch(forceRefresh: true);
      expect(
        await container.read(subscriptionNodesProvider.future),
        hasLength(1),
      );
      expect(api.subscriptionCalls, 1);

      await container
          .read(subscriptionControllerProvider.notifier)
          .applyTrafficSnapshot(total: 10000, used: 2500);
      await Future<void>.delayed(Duration.zero);

      expect(
        await container.read(subscriptionNodesProvider.future),
        hasLength(1),
      );
      expect(api.subscriptionCalls, 1);

      await container
          .read(subscriptionControllerProvider.notifier)
          .applyTrafficSnapshot(total: 10000, used: 2500, canUse: false);
      expect(await container.read(subscriptionNodesProvider.future), isEmpty);
      expect(api.subscriptionCalls, 1);

      await container
          .read(subscriptionControllerProvider.notifier)
          .applyTrafficSnapshot(total: 10000, used: 2500, canUse: true);
      expect(
        await container.read(subscriptionNodesProvider.future),
        hasLength(1),
      );
      expect(api.subscriptionCalls, 2);
    },
  );

  test(
    'hourly automatic refresh downloads nodes without fetching userinfo',
    () async {
      final api = _CountingSubscriptionApi();
      final repository = _SubscriptionRepository(_activeSubscription);
      final container = ProviderContainer(
        overrides: [
          cocoApiProvider.overrideWithValue(api),
          subscriptionRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      await container.read(subscriptionControllerProvider.notifier).fetch();
      await container.read(subscriptionNodesProvider.future);
      expect(repository.fetchCalls, 0);
      expect(api.subscriptionCalls, 1);

      final now = DateTime.now();
      container.read(subscriptionNodesLastRefreshProvider.notifier).state = now
          .subtract(const Duration(hours: 2));
      final refreshed = await container
          .read(subscriptionNodesRefreshControllerProvider.notifier)
          .refreshNodesIfDue(now: now);

      expect(refreshed, isTrue);
      expect(repository.fetchCalls, 0);
      expect(api.subscriptionCalls, 2);

      final duplicate = await container
          .read(subscriptionNodesRefreshControllerProvider.notifier)
          .refreshNodesIfDue(now: now);
      expect(duplicate, isFalse);
      expect(repository.fetchCalls, 0);
      expect(api.subscriptionCalls, 2);

      await container.read(forceSubscriptionNodesRefreshProvider)();
      expect(repository.fetchCalls, 1);
      expect(api.subscriptionCalls, 3);
    },
  );

  test('connection preparation reuses fresh cached nodes', () async {
    final api = _CountingSubscriptionApi();
    final repository = _SubscriptionRepository(_activeSubscription);
    final container = ProviderContainer(
      overrides: [
        cocoApiProvider.overrideWithValue(api),
        subscriptionRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    await container.read(subscriptionControllerProvider.notifier).fetch();
    expect(
      await container.read(subscriptionNodesProvider.future),
      hasLength(1),
    );
    expect(api.subscriptionCalls, 1);

    await container.read(prepareSubscriptionNodesForConnectionProvider)();

    expect(repository.fetchCalls, 0);
    expect(api.subscriptionCalls, 1);
  });

  test('failed automatic node refresh observes its retry cooldown', () async {
    final api = _CountingSubscriptionApi(fail: true);
    final repository = _SubscriptionRepository(_activeSubscription);
    final container = ProviderContainer(
      overrides: [
        cocoApiProvider.overrideWithValue(api),
        subscriptionRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    await container
        .read(subscriptionControllerProvider.notifier)
        .fetch(forceRefresh: true);
    final controller = container.read(
      subscriptionNodesRefreshControllerProvider.notifier,
    );
    final now = DateTime.now();

    await expectLater(controller.refreshNodesIfDue(now: now), throwsException);
    expect(api.subscriptionCalls, 1);
    expect(
      await controller.refreshNodesIfDue(
        now: now.add(const Duration(minutes: 1)),
      ),
      isFalse,
    );
    expect(api.subscriptionCalls, 1);
  });

  test('refresh due policy catches missed foreground intervals once', () {
    final now = DateTime.utc(2030, 1, 1, 12);
    expect(
      isSubscriptionNodesRefreshDue(lastRefreshAt: null, now: now),
      isTrue,
    );
    expect(
      isSubscriptionNodesRefreshDue(
        lastRefreshAt: now.subtract(const Duration(minutes: 59)),
        now: now,
      ),
      isFalse,
    );
    expect(
      isSubscriptionNodesRefreshDue(
        lastRefreshAt: now.subtract(const Duration(hours: 1)),
        now: now,
      ),
      isTrue,
    );
  });
}

const _activeSubscription = SubscriptionStatus(
  isTrial: false,
  isPaid: true,
  paidUntil: '2030-01-01T00:00:00Z',
  canUse: true,
  deviceCount: 1,
  maxDevices: 3,
  subUrl: '',
  trafficTotal: 10000,
  trafficUsed: 1000,
  level: 1,
);

class _CountingSubscriptionApi extends CocoApi {
  _CountingSubscriptionApi({this.fail = false}) : super(_NeverApiService());

  final bool fail;
  int subscriptionCalls = 0;

  @override
  Future<String> subscriptionText({CancelToken? cancelToken}) async {
    subscriptionCalls++;
    if (fail) {
      throw DioException(
        requestOptions: RequestOptions(path: '/v1/link'),
        type: DioExceptionType.connectionError,
      );
    }
    return 'vless://test@127.0.0.1:443#Test';
  }
}

class _SubscriptionRepository implements SubscriptionRepository {
  _SubscriptionRepository(this.status);

  SubscriptionStatus status;
  int fetchCalls = 0;

  @override
  SubscriptionStatus? getCached() => status;

  @override
  bool isCacheFresh() => true;

  @override
  Future<SubscriptionStatus> fetchFresh({CancelToken? cancelToken}) async {
    fetchCalls++;
    return status;
  }

  @override
  Future<SubscriptionStatus?> applyTrafficSnapshot({
    required int total,
    required int used,
    bool? canUse,
    String? paidUntil,
    String? subUrl,
    String? updatedAt,
  }) async {
    status = status.copyWith(
      trafficTotal: total,
      trafficUsed: used,
      canUse: canUse,
      paidUntil: paidUntil,
      subUrl: subUrl,
      updatedAt: updatedAt,
    );
    return status;
  }

  @override
  Future<SubscriptionStatus?> markBlocked() async {
    status = status.copyWith(canUse: false);
    return status;
  }

  @override
  Future<void> clearCache() async {}
}

class _NeverApiService extends ApiService {
  _NeverApiService() : super(Dio());
}
