// lib/features/devices/screens/devices_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vpn_app/core/cache/swr/swr_keys.dart';
import 'package:vpn_app/core/cache/swr/swr_store.dart';
import 'package:vpn_app/core/extensions/context_ext.dart';
import 'package:vpn_app/core/models/feature_state.dart';
import 'package:vpn_app/features/devices/models/domain/device.dart';
import 'package:vpn_app/ui/widgets/app_custom_appbar.dart';
import 'package:vpn_app/ui/widgets/app_snackbar.dart';
import 'package:vpn_app/ui/widgets/themed_scaffold.dart';
import 'package:vpn_app/ui/widgets/atoms/list_tile_x.dart';
import 'package:vpn_app/core/extensions/date_time_ext.dart';

import '../providers/device_providers.dart';

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(swrStoreProvider).touch(SwrKeys.devices));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.tokens;
    final state = ref.watch(deviceControllerProvider);
    const maxDevices = 3;

    final currentTokenAsync = ref.watch(currentDeviceTokenProvider);

    return ThemedScaffold(
      appBar: const AppCustomAppBar(title: '校褋褌褉芯泄褋褌胁邪'),
      body: currentTokenAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('袨褕懈斜泻邪 锌芯谢褍褔械薪懈褟 褌芯泻械薪邪 褍褋褌褉芯泄褋褌胁邪: $e', style: t.typography.body.copyWith(color: c.danger))),
        data: (currentToken) {
          if (state is FeatureLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state is FeatureError<List<Device>>) {
            final message = state.message;
            return Center(child: Text('袨褕懈斜泻邪: $message', style: t.typography.body.copyWith(color: c.danger)));
          }
          final devices = (state is FeatureReady<List<Device>>) ? state.data : const <Device>[];
          return Padding(
              padding: t.spacing.all(t.spacing.md),
              child: Column(
                children: [
                  Card(
                    color: c.bgLight,
                    shape: RoundedRectangleBorder(borderRadius: t.radii.brLg),
                    child: Padding(
                      padding: t.spacing.all(t.spacing.md),
                      child: Center(
                        child: Text(
                          '袩芯写泻谢褞褔械薪芯 褍褋褌褉芯泄褋褌胁: ${devices.length} 懈蟹 $maxDevices',
                          style: t.typography.h3.copyWith(color: c.text),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: t.spacing.sm),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () => ref.read(deviceControllerProvider.notifier).pullToRefresh(),
                      child: devices.isEmpty
                          ? Center(child: Text('袧械褌 褍褋褌褉芯泄褋褌胁', style: t.typography.body.copyWith(color: c.textMuted)))
                          : ListView.separated(
                              itemCount: devices.length,
                              separatorBuilder: (_, _) => Divider(color: c.borderMuted),
                              itemBuilder: (context, i) {
                                final d = devices[i];
                                final isCurrent = d.token == currentToken;

                                return ListTileX(
                                  leadingIcon: Icons.devices_other,
                                  leadingColor: c.primary,
                                  title: '${d.model} (${d.os})',
                                  subtitle: '袩芯褋谢械写薪懈泄 胁褏芯写: ${d.lastSeenUtc.toLocalDate(pattern: "yyyy-MM-dd HH:mm")}',
                                  trailing: isCurrent
                                      ? Tooltip(message: '孝械泻褍褖械械 褍褋褌褉芯泄褋褌胁芯', child: Icon(Icons.lock, color: c.textMuted))
                                      : IconButton(
                                          icon: Icon(Icons.delete, color: c.danger),
                                          tooltip: '袨褌泻谢褞褔懈褌褜',
                                          onPressed: () async {
                                            await ref.read(deviceControllerProvider.notifier).removeByToken(d.token);
                                            if (context.mounted) {
                                              showAppSnackbar(context, text: '校褋褌褉芯泄褋褌胁芯 芯褌泻谢褞褔械薪芯', type: AppSnackbarType.success);
                                            }
                                          },
                                        ),
                                  onTap: null,
                                );
                              },
                            ),
                    ),
                  ),
                ],
              ),
            );
        },
      ),
    );
  }
}



