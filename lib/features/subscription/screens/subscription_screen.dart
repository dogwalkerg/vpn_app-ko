// lib/features/subscription/screens/subscription_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:vpn_app/core/api/api_service.dart';
import 'package:vpn_app/core/api/http_client.dart';
import 'package:vpn_app/core/extensions/context_ext.dart';
import 'package:vpn_app/core/extensions/nav_ext.dart';
import 'package:vpn_app/core/extensions/date_time_ext.dart';

import 'package:vpn_app/features/payments/models/domain/payment_status.dart';
import 'package:vpn_app/features/payments/models/payment_state.dart';
import 'package:vpn_app/features/subscription/models/subscription_status.dart';
import 'package:vpn_app/features/subscription/models/subscription_plan.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/subscription/models/subscription_state.dart';
import 'package:vpn_app/features/subscription/widgets/subscription_confirming_block.dart';
import 'package:vpn_app/ui/widgets/app_custom_appbar.dart';
import 'package:vpn_app/ui/widgets/atoms/primary_button.dart';
import 'package:vpn_app/ui/widgets/themed_scaffold.dart';
import 'package:vpn_app/ui/widgets/app_snackbar.dart';

import 'package:vpn_app/features/payments/providers/payment_providers.dart';
import 'package:vpn_app/features/payments/screens/payment_webview_screen.dart';
import 'package:vpn_app/features/payments/widgets/payment_method_sheet.dart';

import '../widgets/status_card.dart';

class SubscriptionScreen extends ConsumerStatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  ConsumerState<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends ConsumerState<SubscriptionScreen> {
  bool _isWebViewOpen = false;
  late Future<List<SubscriptionPlan>> _plansFuture;

  @override
  void initState() {
    super.initState();
    _plansFuture = _fetchPlans();
    Future.microtask(() => ref.read(subscriptionControllerProvider.notifier).fetch());
  }

  Future<List<SubscriptionPlan>> _fetchPlans() async {
    final api = ref.read(apiServiceProvider);
    final res = await api.get('/subscription/plans');
    final data = (res.data as Map).cast<String, dynamic>();
    final list = (data['plans'] as List? ?? const []);
    return list
        .map((e) => SubscriptionPlan.fromJson((e as Map).cast<String, dynamic>()))
        .where((p) => p.enabled)
        .toList();
  }

  // ===== Helpers UI =====

  ThemedScaffold _screen(Widget body) =>
      ThemedScaffold(appBar: const AppCustomAppBar(title: '订阅'), body: body);

  ({String statusText, String periodText, Color statusColor}) _describeStatus(
    BuildContext context,
    SubscriptionStatus status,
  ) {
    final c = context.colors;
    if (status.isTrial) {
      return (
        statusText: '试用期',
        periodText: '有效期至 ${status.trialEndDate.toLocalDate()}',
        statusColor: c.info
      );
    }
    if (status.isPaid && status.paidUntil != null) {
      return (
        statusText: '订阅已激活',
        periodText: '至 ${status.paidUntil!.toLocalDate()}',
        statusColor: c.success
      );
    }
    return (
      statusText: '订阅未激活',
      periodText: '没有有效的订阅',
      statusColor: c.danger
    );
  }

  Future<void> _onSucceededFlow() async {
    await ref.read(subscriptionControllerProvider.notifier).fetch();
    if (!mounted) return;

    if (_isWebViewOpen) {
      context.pop();
      _isWebViewOpen = false;
    }
    ref.read(paymentControllerProvider.notifier).reset();

    if (!mounted) return;
    showAppSnackbar(context, text: '订阅已激活！', type: AppSnackbarType.success);
  }

  void _onPaymentStateChanged(PaymentState? prev, PaymentState next) {
    final ctrl = ref.read(paymentControllerProvider.notifier);
    final cfg = ref.read(appConfigProvider);

    if (!_isWebViewOpen && next is PaymentReady) {
      _isWebViewOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.pushPayment(
          PaymentWebViewArgs(
            url: next.payment.confirmationUrl!,
            successPrefix: cfg.paymentSuccessPrefix,
            cancelPrefix: cfg.paymentCancelPrefix,
            onSuccess: () async {
              await ctrl.checkPaymentStatus(next.payment.id);
              _isWebViewOpen = false;
            },
            onCancel: () {
              ctrl.reset();
              if (_isWebViewOpen && mounted) context.pop();
              _isWebViewOpen = false;
            },
          ),
        );
      });
      return;
    }

    if (next is PaymentSucceeded) {
      unawaited(_onSucceededFlow());
      return;
    }

    if (next is PaymentCanceled) {
      if (_isWebViewOpen && mounted) {
        context.pop();
        _isWebViewOpen = false;
      }
      ctrl.reset();
    }
  }

  Widget _buildReadyBody(SubscriptionReady ready) {
    final t = context.tokens;
    final c = context.colors;

    final paymentState = ref.watch(paymentControllerProvider);
    final isLoadingPayment = paymentState is PaymentLoading;
    final isPolling = paymentState is PaymentPolling &&
        (paymentState.payment.status == PaymentStatus.pending ||
            paymentState.payment.status == PaymentStatus.waitingForCapture);
    final paymentError = paymentState is PaymentFailed ? paymentState.message : null;

    final desc = _describeStatus(context, ready.status);

    if (isLoadingPayment) {
      return _screen(const Center(child: CircularProgressIndicator()));
    }

    if (paymentError != null) {
      return _screen(
        Padding(
          padding: t.spacing.all(t.spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StatusCard(
                statusText: desc.statusText,
                periodText: desc.periodText,
                statusColor: desc.statusColor,
              ),
              SizedBox(height: t.spacing.xl),
              Text(paymentError, style: t.typography.body.copyWith(color: c.danger)),
              SizedBox(height: t.spacing.md),
              PrimaryButton(
                label: '重试',
                onPressed: ref.read(paymentControllerProvider.notifier).reset,
                icon: Icons.refresh_rounded,
              ),
            ],
          ),
        ),
      );
    }

    return _screen(
      Padding(
        padding: t.spacing.all(t.spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StatusCard(
              statusText: desc.statusText,
              periodText: desc.periodText,
              statusColor: desc.statusColor,
            ),
            SizedBox(height: t.spacing.lg),
            if (!ready.status.isPaid || ready.status.isTrial)
              (isPolling
                  ? const SubscriptionConfirmingBlock()
                  : _PlanChooser(plansFuture: _plansFuture)),
            const Spacer(),
            SizedBox(height: t.spacing.xs),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PaymentState>(paymentControllerProvider, _onPaymentStateChanged);

    final subState = ref.watch(subscriptionControllerProvider);
    switch (subState) {
      case SubscriptionLoading():
        return _screen(const Center(child: CircularProgressIndicator()));
      case SubscriptionError(:final message):
        final t = context.tokens;
        final c = context.colors;
        return _screen(
          Padding(
            padding: t.spacing.all(t.spacing.lg),
            child: Text('错误: $message', style: t.typography.body.copyWith(color: c.danger)),
          ),
        );
      case SubscriptionReady():
        return _buildReadyBody(subState);
      default:
        return _screen(const Center(child: Text('暂无订阅数据')));
    }
  }
}

class _PlanChooser extends ConsumerWidget {
  final Future<List<SubscriptionPlan>> plansFuture;

  const _PlanChooser({required this.plansFuture});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final c = context.colors;

    return FutureBuilder<List<SubscriptionPlan>>(
      future: plansFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final plans = snap.data ?? const <SubscriptionPlan>[];
        if (plans.isEmpty) {
          return PrimaryButton(
            label: '开通默认套餐',
            icon: Icons.diamond_rounded,
            onPressed: () => showPaymentMethodSheet(context, ref),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('选择套餐', style: t.typography.h3.copyWith(color: c.text)),
            SizedBox(height: t.spacing.sm),
            for (final plan in plans) ...[
              _PlanTile(plan: plan),
              SizedBox(height: t.spacing.sm),
            ],
          ],
        );
      },
    );
  }
}

class _PlanTile extends ConsumerWidget {
  final SubscriptionPlan plan;

  const _PlanTile({required this.plan});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final c = context.colors;
    final priceText = plan.price <= 0 ? '免费' : '¥${plan.price.toStringAsFixed(2)}';
    final trafficText = plan.trafficGb >= 1024
        ? '${(plan.trafficGb / 1024).toStringAsFixed(2)} TB'
        : '${plan.trafficGb.toStringAsFixed(0)} GB';

    return InkWell(
      borderRadius: t.radii.brMd,
      onTap: () => showPaymentMethodSheet(
        context,
        ref,
        amount: plan.price,
        planId: plan.id,
      ),
      child: Container(
        padding: t.spacing.all(t.spacing.md),
        decoration: BoxDecoration(
          color: c.bgLight,
          borderRadius: t.radii.brMd,
          border: Border.all(color: c.borderMuted),
        ),
        child: Row(
          children: [
            Icon(Icons.diamond_rounded, color: c.primary, size: t.icons.md),
            SizedBox(width: t.spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(plan.name, style: t.typography.body.copyWith(color: c.text)),
                  SizedBox(height: t.spacing.xs),
                  Text('${plan.days} 天 / $trafficText', style: t.typography.caption.copyWith(color: c.textMuted)),
                ],
              ),
            ),
            Text(priceText, style: t.typography.body.copyWith(color: c.primary)),
          ],
        ),
      ),
    );
  }
}

