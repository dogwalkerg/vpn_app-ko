import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/cache/swr/swr_store.dart';

void main() {
  test('in-flight refresh cannot overwrite an optimistic value', () async {
    final fetch = Completer<String>();
    final entry = SwrEntry<String>(
      key: 'profile',
      fetcher: () => fetch.future,
      ttl: const Duration(minutes: 1),
    );

    final refresh = entry.refresh();
    entry.setOptimistic('optimistic');
    fetch.complete('stale-server-value');

    expect(await refresh, 'optimistic');
    expect(entry.value, 'optimistic');
  });

  test('in-flight refresh cannot restore a cleared value', () async {
    final fetch = Completer<String>();
    final entry = SwrEntry<String>(
      key: 'profile',
      fetcher: () => fetch.future,
      ttl: const Duration(minutes: 1),
    );
    entry.setOptimistic('cached');

    final refresh = entry.refresh();
    entry.clear();
    fetch.complete('stale-server-value');
    await refresh;

    expect(entry.hasValue, isFalse);
    expect(entry.value, isNull);
  });
}
