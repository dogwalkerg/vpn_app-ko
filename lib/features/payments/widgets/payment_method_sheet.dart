import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vpn_app/core/api/coco_api.dart';
import 'package:vpn_app/core/errors/ui_error.dart';
import 'package:vpn_app/features/payments/models/domain/payment_method.dart';
import 'package:vpn_app/features/payments/providers/payment_providers.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/ui/widgets/app_snackbar.dart';

void showPaymentMethodSheet(
  BuildContext context,
  WidgetRef ref, {
  double amount = 1,
  int? planId,
}) {
  showModalBottomSheet(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.account_balance_wallet),
            title: const Text('余额购买套餐'),
            onTap: () {
              Navigator.pop(sheet);
              ref
                  .read(paymentControllerProvider.notifier)
                  .startPayment(
                    method: PaymentMethod.balance,
                    amount: amount,
                    planId: planId,
                  );
            },
          ),
          ListTile(
            leading: const Icon(Icons.payments_outlined),
            title: const Text('余额充值码'),
            onTap: () {
              Navigator.pop(sheet);
              showRechargeCodeDialog(context, ref);
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> showRechargeCodeDialog(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  final code = await showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('余额充值码'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, controller.text),
          child: const Text('确认'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (code == null || code.trim().isEmpty || !context.mounted) return;

  try {
    final user = await ref.read(cocoApiProvider).recharge(code);
    await ref
        .read(subscriptionControllerProvider.notifier)
        .fetch(forceRefresh: true);
    if (!context.mounted) return;
    showAppSnackbar(
      context,
      text: '充值成功，余额 ${user.balance.toStringAsFixed(2)} 自由币',
      type: AppSnackbarType.success,
    );
  } catch (error) {
    if (context.mounted) {
      showAppSnackbar(
        context,
        text: presentableError(error),
        type: AppSnackbarType.error,
      );
    }
  }
}
