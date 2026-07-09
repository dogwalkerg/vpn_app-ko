class SubscriptionNode {
  final String name;
  final String type;
  final String host;
  final int port;
  final String country;
  final String flag;
  final double speedMbps;
  final int load;
  final String raw;

  const SubscriptionNode({
    required this.name,
    required this.type,
    required this.host,
    required this.port,
    required this.country,
    required this.flag,
    required this.speedMbps,
    required this.load,
    required this.raw,
  });
}
