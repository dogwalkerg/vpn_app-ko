// lib/features/auth/screens/verification_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vpn_app/core/extensions/context_ext.dart';
import 'package:vpn_app/core/extensions/nav_ext.dart';
import 'package:vpn_app/core/models/feature_state.dart';
import 'package:vpn_app/features/auth/widgets/auth_fields.dart';
import 'package:vpn_app/ui/widgets/app_snackbar.dart';
import 'package:vpn_app/ui/widgets/atoms/secondary_button.dart';
import 'package:vpn_app/features/auth/providers/auth_providers.dart';
import '../widgets/auth_scaffold.dart';

class VerificationScreen extends ConsumerStatefulWidget {
  final String username;
  final String email;
  const VerificationScreen({super.key, required this.username, required this.email});

  @override
  ConsumerState<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends ConsumerState<VerificationScreen> with AutomaticKeepAliveClientMixin {
  final _code = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    await ref.read(authControllerProvider.notifier).verifyEmail(
          widget.username,
          widget.email,
          _code.text.trim(),
        );

    if (!mounted) return;
    final state = ref.read(authControllerProvider);
    final err = state.errorMessage;
    if (err != null) {
      showAppSnackbar(context, text: err, type: AppSnackbarType.error);
    } else {
      showAppSnackbar(context, text: 'Email 胁械褉懈褎懈褑懈褉芯胁邪薪! 孝械锌械褉褜 胁褘 屑芯卸械褌械 胁芯泄褌懈.', type: AppSnackbarType.success);
      context.goLogin();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final c = context.colors;
    final t = context.tokens;
    final isLoading = ref.watch(authControllerProvider).isLoading;

    return AuthScaffold(
      title: '袙械褉懈褎懈泻邪褑懈褟 Email',
      leading: IconButton(
        icon: Icon(Icons.arrow_back, color: c.textMuted),
        onPressed: () => context.pushRegister(),
      ),
      canPop: false,
      body: Form(
        key: _formKey,
        child: Column(
          children: [
            Icon(Icons.verified_user, size: t.spacing.xxxl, color: c.primary),
            SizedBox(height: t.spacing.md),
            Text(
              '袙胁械写懈褌械 泻芯写, 芯褌锌褉邪胁谢械薪薪褘泄 薪邪 ${widget.email}',
              style: t.typography.body.copyWith(color: c.textMuted),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: t.spacing.sm),
            CodeField(
              controller: _code,
              label: '袣芯写 胁械褉懈褎懈泻邪褑懈懈',
              textInputAction: TextInputAction.done,
              exactLength: 6,
              onSubmitted: (_) => _submit(),
              onCompleted: _submit,
            ),
            SizedBox(height: t.spacing.lg),
            SecondaryButton(
              label: '袩芯写褌胁械褉写懈褌褜 Email',
              onPressed: isLoading ? null : _submit,
              icon: Icons.verified_rounded,
            ),
          ],
        ),
      ),
    );
  }
}
