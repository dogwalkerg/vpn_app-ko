import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpn_app/core/storage/shared_preferences_provider.dart';
import 'package:vpn_app/features/vpn/models/subscription_node.dart';
import 'package:vpn_app/features/vpn/providers/subscription_nodes_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final nodes = [
    _node('Node A', 443),
    _node('Node B', 8443),
    _node('Node C', 2096),
  ];

  test('smart selection chooses the lowest successful latency', () async {
    final latencies = <String, int?>{
      nodes[0].raw: 80,
      nodes[1].raw: null,
      nodes[2].raw: 20,
    };
    final container = ProviderContainer(
      overrides: [
        selectedSubscriptionNodeProvider.overrideWith((ref) => nodes.first),
        nodeLatencyProbeProvider.overrideWithValue(
          (node) async => latencies[node.raw],
        ),
      ],
    );
    addTearDown(container.dispose);

    final selected = await container
        .read(nodeSelectionModeProvider.notifier)
        .selectSmart(nodes: nodes);

    expect(selected?.raw, nodes[2].raw);
    expect(container.read(selectedSubscriptionNodeProvider)?.raw, nodes[2].raw);
    expect(container.read(nodeSelectionModeProvider), NodeSelectionMode.smart);
  });

  test(
    'smart selection keeps a valid fallback when every probe fails',
    () async {
      final selected = await selectLowestLatencyNode(
        nodes: nodes,
        probe: (_) async => null,
        fallback: nodes[1],
      );

      expect(selected?.raw, nodes[1].raw);
    },
  );

  test('manual selection invalidates an in-flight smart result', () async {
    final slowProbeStarted = Completer<void>();
    final releaseSlowProbe = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        selectedSubscriptionNodeProvider.overrideWith((ref) => nodes.first),
        nodeLatencyProbeProvider.overrideWithValue((node) async {
          if (node.raw == nodes[2].raw) {
            slowProbeStarted.complete();
            await releaseSlowProbe.future;
            return 10;
          }
          return 80;
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(nodeSelectionModeProvider.notifier);

    final smartSelection = controller.selectSmart(nodes: nodes);
    await slowProbeStarted.future;
    await controller.selectManual(nodes[0]);
    releaseSlowProbe.complete();
    await smartSelection;

    expect(container.read(nodeSelectionModeProvider), NodeSelectionMode.manual);
    expect(container.read(selectedSubscriptionNodeProvider)?.raw, nodes[0].raw);
  });

  test('selection mode persists without storing a node URI', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        nodeLatencyProbeProvider.overrideWithValue((_) async => 20),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(nodeSelectionModeProvider.notifier);

    await controller.selectSmart(nodes: [nodes.first]);
    expect(
      preferences.getString(nodeSelectionModePreferenceKey),
      NodeSelectionMode.smart.name,
    );
    expect(preferences.getKeys(), {nodeSelectionModePreferenceKey});

    await controller.selectManual(nodes[1]);
    expect(
      preferences.getString(nodeSelectionModePreferenceKey),
      NodeSelectionMode.manual.name,
    );
  });

  test(
    'a new controller restores smart mode and rejects invalid values',
    () async {
      SharedPreferences.setMockInitialValues({
        nodeSelectionModePreferenceKey: NodeSelectionMode.smart.name,
      });
      final smartPreferences = await SharedPreferences.getInstance();
      final smartContainer = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(smartPreferences),
        ],
      );
      expect(
        smartContainer.read(nodeSelectionModeProvider),
        NodeSelectionMode.smart,
      );
      smartContainer.dispose();

      SharedPreferences.setMockInitialValues({
        nodeSelectionModePreferenceKey: 'invalid',
      });
      final invalidPreferences = await SharedPreferences.getInstance();
      final invalidContainer = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(invalidPreferences),
        ],
      );
      addTearDown(invalidContainer.dispose);
      expect(
        invalidContainer.read(nodeSelectionModeProvider),
        NodeSelectionMode.manual,
      );
    },
  );

  test(
    'clearing a session prevents a late smart result restoring a node',
    () async {
      final probeStarted = Completer<void>();
      final releaseProbe = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          selectedSubscriptionNodeProvider.overrideWith((ref) => nodes.first),
          nodeLatencyProbeProvider.overrideWithValue((_) async {
            if (!probeStarted.isCompleted) probeStarted.complete();
            await releaseProbe.future;
            return 10;
          }),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(nodeSelectionModeProvider.notifier);

      final smartSelection = controller.selectSmart(nodes: nodes);
      await probeStarted.future;
      controller.cancelPendingSelection(clearNode: true);
      releaseProbe.complete();
      await smartSelection;

      expect(
        container.read(nodeSelectionModeProvider),
        NodeSelectionMode.smart,
      );
      expect(container.read(selectedSubscriptionNodeProvider), isNull);
    },
  );

  test(
    'clearing a session during persistence prevents probing old nodes',
    () async {
      final persistenceStarted = Completer<void>();
      final releasePersistence = Completer<void>();
      var probeCalls = 0;
      final container = ProviderContainer(
        overrides: [
          selectedSubscriptionNodeProvider.overrideWith((ref) => nodes.first),
          nodeSelectionModePersistenceProvider.overrideWithValue((_) async {
            persistenceStarted.complete();
            await releasePersistence.future;
          }),
          nodeLatencyProbeProvider.overrideWithValue((_) async {
            probeCalls++;
            return 10;
          }),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(nodeSelectionModeProvider.notifier);

      final smartSelection = controller.selectSmart(nodes: nodes);
      await persistenceStarted.future;
      controller.cancelPendingSelection(clearNode: true);
      releasePersistence.complete();

      expect(await smartSelection, isNull);
      expect(probeCalls, 0);
      expect(container.read(selectedSubscriptionNodeProvider), isNull);
    },
  );

  test('a refreshed node revision invalidates an old probe result', () async {
    final oldNode = nodes.first;
    final newNode = nodes.last;
    final oldProbeStarted = Completer<void>();
    final releaseOldProbe = Completer<void>();
    var currentNodes = [oldNode];
    final container = ProviderContainer(
      overrides: [
        subscriptionNodesProvider.overrideWith((ref) async => currentNodes),
        selectedSubscriptionNodeProvider.overrideWith((ref) => oldNode),
        nodeLatencyProbeProvider.overrideWithValue((node) async {
          if (node.raw == oldNode.raw) {
            oldProbeStarted.complete();
            await releaseOldProbe.future;
            return 5;
          }
          return 20;
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.read(subscriptionNodesProvider.future);
    final controller = container.read(nodeSelectionModeProvider.notifier);

    final smartSelection = controller.selectSmart(nodes: currentNodes);
    await oldProbeStarted.future;
    currentNodes = [newNode];
    container.read(subscriptionNodesRevisionProvider.notifier).state++;
    container.invalidate(subscriptionNodesProvider);
    await container.read(subscriptionNodesProvider.future);
    releaseOldProbe.complete();

    expect((await smartSelection)?.raw, newNode.raw);
    expect(container.read(selectedSubscriptionNodeProvider)?.raw, newNode.raw);
  });

  test(
    'refresh completion during persistence discards the supplied snapshot',
    () async {
      final oldNode = nodes.first;
      final newNode = nodes.last;
      final persistenceStarted = Completer<void>();
      final releasePersistence = Completer<void>();
      var currentNodes = [oldNode];
      final container = ProviderContainer(
        overrides: [
          subscriptionNodesProvider.overrideWith((ref) async => currentNodes),
          selectedSubscriptionNodeProvider.overrideWith((ref) => oldNode),
          nodeSelectionModePersistenceProvider.overrideWithValue((_) async {
            persistenceStarted.complete();
            await releasePersistence.future;
          }),
          nodeLatencyProbeProvider.overrideWithValue((_) async => 10),
        ],
      );
      addTearDown(container.dispose);
      await container.read(subscriptionNodesProvider.future);
      final controller = container.read(nodeSelectionModeProvider.notifier);

      final smartSelection = controller.selectSmart(nodes: currentNodes);
      await persistenceStarted.future;
      currentNodes = [newNode];
      container.read(subscriptionNodesRevisionProvider.notifier).state++;
      container.invalidate(subscriptionNodesProvider);
      await container.read(subscriptionNodesProvider.future);
      releasePersistence.complete();

      expect((await smartSelection)?.raw, newNode.raw);
      expect(
        container.read(selectedSubscriptionNodeProvider)?.raw,
        newNode.raw,
      );
    },
  );

  test('desktop smart selection only considers compatible VLESS nodes', () {
    final vless = nodes.first;
    final trojan = SubscriptionNode(
      name: 'Trojan',
      type: 'TROJAN',
      host: '127.0.0.1',
      port: 443,
      country: 'Test',
      flag: '',
      speedMbps: 0,
      load: 0,
      raw: 'trojan://test@127.0.0.1:443#Trojan',
    );

    expect(
      isNodeCompatibleWithSmartSelection(vless, desktopMihomo: true),
      isTrue,
    );
    expect(
      isNodeCompatibleWithSmartSelection(trojan, desktopMihomo: true),
      isFalse,
    );
  });
}

SubscriptionNode _node(String name, int port) => SubscriptionNode(
  name: name,
  type: 'VLESS',
  host: '127.0.0.1',
  port: port,
  country: 'Test',
  flag: '',
  speedMbps: 0,
  load: 0,
  raw: 'vless://test@127.0.0.1:$port#$name',
);
