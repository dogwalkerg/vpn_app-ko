// lib/features/subscription/repositories/subscription_repository_impl.dart
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:vpn_app/core/api/api_service.dart';
import 'package:vpn_app/core/api/coco_api.dart';
import 'package:vpn_app/core/cache/swr/swr_keys.dart';
import 'package:vpn_app/core/cache/swr/swr_store.dart';
import 'package:vpn_app/features/subscription/mappers/subscription_mapper.dart';
import '../../../core/cache/disk_cache.dart';
import '../models/subscription_status.dart';
import 'subscription_repository.dart';

class SubscriptionRepositoryImpl implements SubscriptionRepository {
  SubscriptionRepositoryImpl(
    this.api, {
    this.ttl = const Duration(seconds: 60),
    required SwrStore swr,
  }) : _entry = swr.register<SubscriptionStatus>(
          key: SwrKeys.subscription,
          ttl: ttl,
          fetcher: () async {
            final data = _toStatusMap(await CocoApi(api).userInfo());
            // Сохраним снапшот
            unawaited(DiskCache.putJson(SwrKeys.subscription, data));
            return subscriptionStatusFromMap(data);
          },
        ) {
    // Гидратация из снапшота
    _hydrateFromSnapshot();
  }

  final ApiService api;
  final Duration ttl;
  final SwrEntry<SubscriptionStatus> _entry;

  Future<void> _hydrateFromSnapshot() async {
    final snap = await DiskCache.getJson<Map>(SwrKeys.subscription, ttl: ttl);
    if (snap != null && snap.isNotEmpty) {
      final mapped = subscriptionStatusFromMap(snap.cast<String, dynamic>());
      _entry.setOptimistic(mapped);
    }
  }

  @override
  SubscriptionStatus? getCached() => _entry.value;

  @override
  bool isCacheFresh() => _entry.value != null;

  @override
  Future<SubscriptionStatus> fetchFresh({CancelToken? cancelToken}) async {
    try {
      final data = _toStatusMap(await CocoApi(api).userInfo(cancelToken: cancelToken));
      final fresh = subscriptionStatusFromMap(data);

      // кладём свежие данные и снапшот
      _entry.setOptimistic(fresh);
      unawaited(DiskCache.putJson(SwrKeys.subscription, data));
      return fresh;
    } on DioException catch (e) {
      throw mapDioError(e);
    }
  }
}

Map<String, dynamic> _toStatusMap(CocoUserInfo user) => {
      'is_trial': false,
      'is_paid': user.canUse,
      'paid_until': user.expiresAt?.toIso8601String(),
      'can_use': user.canUse,
      'device_count': 0,
      'max_devices': 0,
      'balance': user.balance,
      'sub_url': user.subscriptionUrl,
      'traffic_total': user.trafficTotal,
      'traffic_used': user.trafficUsed,
      'level': user.level,
    };
