// lib/features/subscription/repositories/subscription_repository_impl.dart
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:vpn_app/core/api/api_service.dart';
import 'package:vpn_app/core/api/coco_api.dart';
import 'package:vpn_app/core/cache/swr/swr_keys.dart';
import 'package:vpn_app/core/cache/swr/swr_store.dart';
import 'package:vpn_app/core/errors/error_mapper.dart';
import 'package:vpn_app/features/subscription/mappers/subscription_mapper.dart';
import '../../../core/cache/disk_cache.dart';
import '../models/subscription_status.dart';
import 'subscription_repository.dart';

class SubscriptionRepositoryImpl implements SubscriptionRepository {
  SubscriptionRepositoryImpl(
    this.api, {
    this.ttl = const Duration(seconds: 60),
    required SwrStore swr,
  }) : _entry = swr.register<SubscriptionStatus?>(
         key: SwrKeys.subscription,
         ttl: ttl,
         revalidateOnResume: false,
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
  final SwrEntry<SubscriptionStatus?> _entry;
  int _cacheRevision = 0;

  Future<void> _hydrateFromSnapshot() async {
    final revision = _cacheRevision;
    final snap = await DiskCache.getJson<Map>(SwrKeys.subscription, ttl: ttl);
    if (revision == _cacheRevision && snap != null && snap.isNotEmpty) {
      final mapped = subscriptionStatusFromMap(snap.cast<String, dynamic>());
      _entry.setOptimistic(mapped);
    }
  }

  @override
  SubscriptionStatus? getCached() => _entry.value;

  @override
  bool isCacheFresh() => _entry.isFresh;

  @override
  Future<SubscriptionStatus> fetchFresh({CancelToken? cancelToken}) async {
    final revision = _cacheRevision;
    try {
      final data = _toStatusMap(
        await CocoApi(api).userInfo(cancelToken: cancelToken),
      );
      var fresh = subscriptionStatusFromMap(data);

      if (revision != _cacheRevision) {
        final current = getCached();
        if (current != null) {
          final freshUpdatedAt = DateTime.tryParse(fresh.updatedAt ?? '');
          final currentUpdatedAt = DateTime.tryParse(current.updatedAt ?? '');
          final freshIsOlder =
              currentUpdatedAt != null &&
              (freshUpdatedAt == null ||
                  freshUpdatedAt.isBefore(currentUpdatedAt));
          if (freshIsOlder) return current;
          final used = fresh.trafficUsed > current.trafficUsed
              ? fresh.trafficUsed
              : current.trafficUsed;
          fresh = fresh.copyWith(
            trafficUsed: used,
            canUse:
                fresh.canUse &&
                fresh.trafficTotal > 0 &&
                used < fresh.trafficTotal,
          );
        }
      }

      // кладём свежие данные и снапшот
      _entry.setOptimistic(fresh);
      unawaited(DiskCache.putJson(SwrKeys.subscription, _statusToMap(fresh)));
      return fresh;
    } on DioException catch (e) {
      throw mapDioError(e);
    }
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
    final current = getCached();
    if (current == null) return null;
    _cacheRevision++;
    final updated = current.copyWith(
      trafficTotal: total,
      trafficUsed: used,
      canUse: canUse,
      paidUntil: paidUntil,
      subUrl: subUrl,
      updatedAt: updatedAt,
    );
    await _persist(updated);
    return updated;
  }

  @override
  Future<SubscriptionStatus?> markBlocked() async {
    final current = getCached();
    if (current == null) return null;
    _cacheRevision++;
    final updated = current.copyWith(canUse: false);
    await _persist(updated);
    return updated;
  }

  @override
  Future<void> clearCache() async {
    _cacheRevision++;
    _entry.clear();
    try {
      await DiskCache.remove(SwrKeys.subscription);
    } catch (_) {}
  }

  Future<void> _persist(SubscriptionStatus status) async {
    _entry.setOptimistic(status);
    try {
      await DiskCache.putJson(SwrKeys.subscription, _statusToMap(status));
    } catch (_) {}
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
  'updated_at': user.updatedAt?.toIso8601String(),
};

Map<String, dynamic> _statusToMap(SubscriptionStatus status) => {
  'is_trial': status.isTrial,
  'trial_end_date': status.trialEndDate,
  'is_paid': status.isPaid,
  'paid_until': status.paidUntil,
  'can_use': status.canUse,
  'device_count': status.deviceCount,
  'max_devices': status.maxDevices,
  'balance': status.balance,
  'sub_url': status.subUrl,
  'traffic_total': status.trafficTotal,
  'traffic_used': status.trafficUsed,
  'level': status.level,
  'updated_at': status.updatedAt,
};
