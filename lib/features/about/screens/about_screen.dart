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
      appBar: const AppCustomAppBar(title: '袨 锌褉懈谢芯卸械薪懈懈'),
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
                        'UgbuganVPN 鈥?褝褌芯 锌褉芯 薪邪写褢卸薪芯褋褌褜, 褋泻芯褉芯褋褌褜 懈 泻芯谢芯褉懈褌!',
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
                        '袙械褉褋懈褟',
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
                        '袪邪蟹褉邪斜芯褌褔懈泻懈',
                        textAlign: TextAlign.center,
                        style: t.typography.h3.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: t.spacing.xxs),
                      Text(
                        '袗斜写褍褉邪褏屑邪薪芯胁 袚邪褋邪薪\n楔邪屑芯胁 袚邪写卸懈泻褍褉斜邪薪',
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
                      tooltip: '袩芯褔褌邪',
                      onPressed: () async {
                        final uri = Uri(
                          scheme: 'mailto',
                          path: 'support@vpnapp.com',
                          query: 'subject=袨斜褉邪褖械薪懈械 褔械褉械蟹 锌褉懈谢芯卸械薪懈械',
                        );
                        await _openUri(uri);
                      },
                    ),
                    SizedBox(width: t.spacing.lg),
                    IconButton(
                      icon: Icon(Icons.language, color: c.primary, size: t.icons.xl),
                      tooltip: '小邪泄褌',
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
                      '袩芯谢懈褌懈泻邪 泻芯薪褎懈写械薪褑懈邪谢褜薪芯褋褌懈',
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
