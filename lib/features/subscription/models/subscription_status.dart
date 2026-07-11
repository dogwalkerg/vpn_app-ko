// lib/features/subscription/models/subscription_status.dart
class SubscriptionStatus {
  final bool isTrial;
  final String? trialEndDate;
  final bool isPaid;
  final String? paidUntil;
  final bool canUse;
  final int deviceCount;
  final int maxDevices;
  final double balance;
  final String subUrl;
  final int trafficTotal;
  final int trafficUsed;
  final int level;

  const SubscriptionStatus({
    required this.isTrial,
    this.trialEndDate,
    required this.isPaid,
    this.paidUntil,
    required this.canUse,
    required this.deviceCount,
    required this.maxDevices,
    this.balance = 0,
    this.subUrl = '',
    this.trafficTotal = 0,
    this.trafficUsed = 0,
    this.level = 0,
  });

  factory SubscriptionStatus.fromJson(Map<String, dynamic> json) {
    String? str(dynamic v) => v?.toString();

    return SubscriptionStatus(
      isTrial: (json['is_trial'] ?? json['isTrial'] ?? false) == true,
      trialEndDate: str(json['trial_end_date'] ?? json['trialEndDate'] ?? json['end_date']),
      isPaid: (json['is_paid'] ?? json['isPaid'] ?? false) == true,
      paidUntil: str(json['paid_until'] ?? json['paidUntil'] ?? json['end_date']),
      canUse: (json['can_use'] ?? json['canUse'] ?? false) == true,
      deviceCount: (json['device_count'] ?? json['deviceCount'] ?? 0) as int,
      maxDevices: (json['max_devices'] ?? json['maxDevices'] ?? 3) as int,
      balance: ((json['balance'] ?? 0) as num).toDouble(),
      subUrl: str(json['sub_url'] ?? json['subUrl']) ?? '',
      trafficTotal: (json['traffic_total'] as num? ?? 0).toInt(),
      trafficUsed: (json['traffic_used'] as num? ?? 0).toInt(),
      level: (json['level'] as num? ?? 0).toInt(),
    );
  }
}
