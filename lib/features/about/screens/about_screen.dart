// lib/features/about/screens/about_screen.dart
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vpn_app/core/extensions/context_ext.dart';
import 'package:vpn_app/ui/widgets/app_custom_appbar.dart';
import 'package:vpn_app/ui/widgets/themed_scaffold.dart';
import 'package:vpn_app/ui/widgets/atoms/app_surface.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<void> _openUri(Uri uri) async {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.tokens;

    return ThemedScaffold(
      appBar: const AppCustomAppBar(title: '关于应用'),
      body: Center(
        child: SingleChildScrollView(
          padding: t.spacing.all(t.spacing.md),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppSurface(
                  radius: t.radii.brXl,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/icons/about_icon.png',
                        width: t.spacing.xxxl * 2,
                        height: t.spacing.xxxl * 2,
                        fit: BoxFit.contain,
                      ),
                      SizedBox(height: t.spacing.md),
                      Text(
                        'UgbuganVPN',
                        textAlign: TextAlign.center,
                        style: t.typography.h2.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: t.spacing.md),
                      Text(
                        '安全、稳定、快速的 VPN 客户端。',
                        textAlign: TextAlign.center,
                        style: t.typography.body.copyWith(
                          color: c.textMuted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),

                SizedBox(height: t.spacing.md),

                AppSurface(
                  radius: t.radii.brLg,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        '版本',
                        textAlign: TextAlign.center,
                        style: t.typography.h3.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: t.spacing.xxs),
                      Text(
                        '1.0.0',
                        textAlign: TextAlign.center,
                        style: t.typography.bodySm.copyWith(color: c.textMuted),
                      ),
                      SizedBox(height: t.spacing.sm),
                      Text(
                        '开发者',
                        textAlign: TextAlign.center,
                        style: t.typography.h3.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: t.spacing.xxs),
                      Text(
                        'UgbuganVPN 团队',
                        textAlign: TextAlign.center,
                        style: t.typography.bodySm.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),

                SizedBox(height: t.spacing.lg),

                // Social / links
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: Icon(Icons.email, color: c.primary, size: t.icons.xl),
                      tooltip: '邮箱',
                      onPressed: () async {
                        final uri = Uri(
                          scheme: 'mailto',
                          path: 'support@vpnapp.com',
                          query: 'subject=应用反馈',
                        );
                        await _openUri(uri);
                      },
                    ),
                    SizedBox(width: t.spacing.lg),
                    IconButton(
                      icon: Icon(Icons.language, color: c.primary, size: t.icons.xl),
                      tooltip: '官网',
                      onPressed: () async {
                        await _openUri(Uri.parse('https://ugbuganvpn.com'));
                      },
                    ),
                    SizedBox(width: t.spacing.lg),
                    IconButton(
                      icon: Icon(Icons.telegram, color: c.primary, size: t.icons.xl),
                      tooltip: 'Telegram',
                      onPressed: () async {
                        await _openUri(Uri.parse('https://t.me/ugbuganvpn'));
                      },
                    ),
                  ],
                ),

                SizedBox(height: t.spacing.md),

                Center(
                  child: GestureDetector(
                    onTap: () => _openUri(Uri.parse('https://ugbuganvpn.com/privacy')),
                    child: Text(
                      '隐私政策',
                      style: t.typography.body.copyWith(
                        color: c.primary,
                        decoration: TextDecoration.underline,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
