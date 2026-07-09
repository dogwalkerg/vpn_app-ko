// lib/ui/widgets/app_drawer.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vpn_app/core/extensions/context_ext.dart';
import 'package:vpn_app/core/extensions/nav_ext.dart';
import 'package:vpn_app/ui/theme/theme_provider.dart';
import 'package:vpn_app/features/auth/providers/auth_providers.dart';
import 'package:vpn_app/ui/widgets/atoms/list_tile_x.dart';
import 'package:vpn_app/ui/widgets/app_snackbar.dart';

class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.tokens;

    final isAuth = ref.watch(isAuthenticatedProvider);
    final username = ref.watch(currentUsernameProvider);

    return Drawer(
      backgroundColor: c.bg,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: EdgeInsets.only(top: t.spacing.xl, bottom: t.spacing.lg),
            color: c.bg,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Padding(
                  padding: EdgeInsets.all(t.spacing.xs),
                  child: Opacity(
                    opacity: t.opacities.focus,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(shape: BoxShape.circle),
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: c.primary, shape: BoxShape.circle),
                        child: Padding(
                          padding: EdgeInsets.all(t.spacing.xs),
                          child: Icon(Icons.account_circle, size: t.spacing.xxl, color: c.text),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: t.spacing.sm),
                Text(username ?? '访客', style: t.typography.h2.copyWith(color: c.text)),
              ],
            ),
          ),

          ListTileX(
            leadingIcon: Icons.diamond_rounded,
            leadingColor: c.primary,
            title: '订阅套餐',
            onTap: () {
              context.pop();
              rootCtx.pushSubscription();
            },
          ),
          ListTileX(
            leadingIcon: Icons.devices,
            leadingColor: c.info,
            title: '设备管理',
            onTap: () {
              context.pop();
              rootCtx.pushDevices();
            },
          ),
          ListTileX(
            leadingIcon: Icons.info_outline,
            leadingColor: c.secondary,
            title: '关于应用',
            onTap: () {
              context.pop();
              rootCtx.pushAbout();
            },
          ),
          const Spacer(),
          ListTileX(
            leadingIcon: Icons.brightness_6,
            leadingColor: c.highlight,
            title: '切换主题',
            onTap: () {
              ref.read(themeProvider).toggleTheme();
              final newMode = ref.read(themeProvider).themeMode;
              showAppSnackbar(
                context,
                text: '主题已切换为${newMode == ThemeMode.dark ? '深色' : '浅色'}模式',
                type: AppSnackbarType.info,
              );
            },
          ),

          if (isAuth)
            ListTileX(
              leadingIcon: Icons.logout,
              leadingColor: c.danger,
              title: '退出登录',
              onTap: () async {
                rootCtxOrNull?.pop();
                ref.read(authControllerProvider.notifier).logout();
                rootCtx.goLogin();
              },
            ),
          SizedBox(height: t.spacing.sm),
        ],
      ),
    );
  }
}


