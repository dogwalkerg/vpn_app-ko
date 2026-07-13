import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/features/payments/widgets/payment_method_sheet.dart';

void main() {
  testWidgets('plan payment sheet only shows the two supported choices', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () =>
                    showPaymentMethodSheet(context, ref, amount: 15, planId: 3),
                child: const Text('打开购买方式'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开购买方式'));
    await tester.pumpAndSettle();

    expect(find.text('余额购买套餐'), findsOneWidget);
    expect(find.text('余额充值码'), findsOneWidget);
    expect(find.text('套餐兑换码'), findsNothing);
  });
}
