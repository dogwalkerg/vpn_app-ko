class SubscriptionPlan {
  final int id;
  final String name;
  final int days;
  final double trafficGb;
  final double price;
  final bool enabled;

  const SubscriptionPlan({
    required this.id,
    required this.name,
    required this.days,
    required this.trafficGb,
    required this.price,
    required this.enabled,
  });

  factory SubscriptionPlan.fromJson(Map<String, dynamic> json) {
    return SubscriptionPlan(
      id: (json['id'] as num).toInt(),
      name: (json['name'] ?? '套餐').toString(),
      days: ((json['duration_days'] ?? json['days']) as num? ?? 30).toInt(),
      trafficGb: json['traffic_bytes'] != null
          ? ((json['traffic_bytes'] as num).toDouble() / (1024 * 1024 * 1024))
          : (json['traffic_gb'] as num? ?? 0).toDouble(),
      price: (json['price'] as num? ?? 0).toDouble(),
      enabled: (json['status'] ?? json['enabled'] ?? 1) == 1 ||
          json['status'] == true || json['enabled'] == true,
    );
  }
}
