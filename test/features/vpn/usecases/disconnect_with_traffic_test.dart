import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/features/vpn/usecases/disconnect_with_traffic.dart';

void main() {
  test('a blocked traffic report does not delay the VPN stop', () async {
    final initialFlush = Completer<bool>();
    final disconnect = Completer<void>();
    final events = <String>[];
    var flushCalls = 0;

    final operation = disconnectWithTrafficSync(
      flushTraffic: () {
        flushCalls++;
        events.add('flush-$flushCalls');
        return flushCalls == 1 ? initialFlush.future : Future.value(true);
      },
      disconnectVpn: () {
        events.add('disconnect');
        return disconnect.future;
      },
    );

    await Future<void>.delayed(Duration.zero);
    expect(events, ['flush-1', 'disconnect']);

    disconnect.complete();
    await Future<void>.delayed(Duration.zero);
    expect(events, ['flush-1', 'disconnect']);

    initialFlush.complete(false);
    await operation;
    expect(events, ['flush-1', 'disconnect', 'flush-2']);
  });
}
