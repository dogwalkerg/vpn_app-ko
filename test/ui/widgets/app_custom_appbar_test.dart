import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/ui/theme/light_theme.dart';
import 'package:vpn_app/ui/widgets/app_custom_appbar.dart';

void main() {
  testWidgets('uses dark content over a transparent mobile status bar', (
    tester,
  ) async {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme.copyWith(platform: platform),
          home: const Scaffold(appBar: AppCustomAppBar(title: 'Osca')),
        ),
      );

      final style = tester
          .widget<AppBar>(find.byType(AppBar))
          .systemOverlayStyle;
      expect(style?.statusBarColor, Colors.transparent);
      expect(style?.statusBarBrightness, Brightness.light);
      expect(style?.statusBarIconBrightness, Brightness.dark);
    }
  });

  testWidgets('keeps the platform default status bar on desktop', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme.copyWith(platform: TargetPlatform.windows),
        home: const Scaffold(appBar: AppCustomAppBar(title: 'Osca')),
      ),
    );

    expect(
      tester.widget<AppBar>(find.byType(AppBar)).systemOverlayStyle,
      isNull,
    );
  });
}
