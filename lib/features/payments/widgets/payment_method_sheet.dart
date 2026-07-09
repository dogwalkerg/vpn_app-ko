// lib/features/payments/widgets/payment_method_sheet.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vpn_app/core/api/api_service.dart';
import 'package:vpn_app/core/extensions/context_ext.dart';
import 'package:vpn_app/core/errors/ui_error.dart';
import 'package:vpn_app/features/payments/models/domain/payment_method.dart';
import 'package:vpn_app/features/payments/providers/payment_providers.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/ui/widgets/app_snackbar.dart';

void showPaymentMethodSheet(
  BuildContext context,
  WidgetRef ref, {
  double amount = 1.0,
  int? planId,
}) {
  final c = context.colors;
  final t = context.tokens;
  final ctrl = ref.read(paymentControllerProvider.notifier);

  showModalBottomSheet(
    context: context,
    backgroundColor: c.bgLight,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(t.radii.xl)),
    ),
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: t.spacing.xs),
        Container(
          width: t.spacing.xxl,
          height: t.spacing.xs * 0.6,
          margin: EdgeInsets.only(bottom: t.spacing.xs),
          decoration: BoxDecoration(
            color: c.borderMuted,
            borderRadius: BorderRadius.circular(t.radii.sm),
          ),
        ),
        _SheetButton(
          icon: Icons.account_balance_wallet_rounded,
          label: '余额支付',
          onTap: () {
            Navigator.of(ctx).pop();
            ctrl.startPayment(
              method: PaymentMethod.balance,
              amount: amount,
              planId: planId,
            );
          },
        ),
        _SheetButton(
          icon: Icons.confirmation_number_rounded,
          label: '充值',
          onTap: () {
            Navigator.of(ctx).pop();
            showRechargeCodeDialog(context, ref);
          },
        ),
        SizedBox(height: t.spacing.md),
      ],
    ),
  );
}

Future<void> showRechargeCodeDialog(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  final code = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('充值'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(
          labelText: '充值码',
          hintText: '请输入后台生成的充值码',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: const Text('充值'),
        ),
      ],
    ),
  );
  controller.dispose();

  final trimmed = code?.trim();
  if (trimmed == null || trimmed.isEmpty) return;

  try {
    final api = ref.read(apiServiceProvider);
    final res = await api.post('/subscription/redeem', data: {'code': trimmed});
    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw Exception('充值失败');
    }
    await ref.read(subscriptionControllerProvider.notifier).fetch();
    final data = (res.data is Map) ? (res.data as Map).cast<String, dynamic>() : {};
    final balance = (data['balance'] as num?)?.toDouble();
    showAppSnackbar(
      context,
      text: balance == null ? '充值成功' : '充值成功，当前余额 ${balance.toStringAsFixed(2)}',
      type: AppSnackbarType.success,
    );
  } catch (e) {
    showAppSnackbar(context, text: presentableError(e), type: AppSnackbarType.error);
  }
}

class _SheetButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SheetButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.tokens;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.spacing.lg, vertical: t.spacing.xs),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, color: c.primary, size: t.icons.md),
          label: Text(label, style: t.typography.body.copyWith(color: c.text)),
          style: ElevatedButton.styleFrom(
            backgroundColor: c.bg,
            foregroundColor: c.text,
            shape: RoundedRectangleBorder(borderRadius: t.radii.brMd),
            elevation: t.elevations.none,
            padding: EdgeInsets.symmetric(
              horizontal: t.spacing.md,
              vertical: t.spacing.sm,
            ),
          ),
        ),
      ),
    );
  }
}
