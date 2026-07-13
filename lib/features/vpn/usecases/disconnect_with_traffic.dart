Future<void> disconnectWithTrafficSync({
  required Future<bool> Function() flushTraffic,
  required Future<void> Function() disconnectVpn,
}) async {
  // Start both operations before awaiting either one. Remote accounting must
  // never keep the system proxy enabled while it waits for the backend.
  final initialFlush = flushTraffic().catchError((_) => false);
  final disconnect = disconnectVpn();

  await disconnect;
  await initialFlush;
  await flushTraffic().catchError((_) => false);
}
