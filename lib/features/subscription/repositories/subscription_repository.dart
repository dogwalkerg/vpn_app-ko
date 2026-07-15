// lib/features/subscription/repositories/subscription_repository.dart
import 'package:dio/dio.dart' show CancelToken;
import '../models/subscription_status.dart';

abstract class SubscriptionRepository {
  SubscriptionStatus? getCached();
  bool isCacheFresh();
  Future<SubscriptionStatus> fetchFresh({CancelToken? cancelToken});
  Future<SubscriptionStatus?> applyTrafficSnapshot({
    required int total,
    required int used,
    bool? canUse,
    String? paidUntil,
    String? subUrl,
    String? updatedAt,
  });
  Future<SubscriptionStatus?> markBlocked();
  Future<void> clearCache();
}
