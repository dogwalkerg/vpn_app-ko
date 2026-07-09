// lib/features/subscription/widgets/subscription_confirming_block.dart
import 'package:flutter/material.dart';
import 'package:vpn_app/core/extensions/context_ext.dart';

class SubscriptionConfirmingBlock extends StatelessWidget {
  const SubscriptionConfirmingBlock({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.tokens;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: t.spacing.md, vertical: t.spacing.sm),
      decoration: BoxDecoration(
        color: c.bgLight,
        borderRadius: t.radii.brMd,
        border: Border.all(color: c.borderMuted, width: 1),
      ),
      child: Row(
        children: [
          SizedBox(
            width: t.icons.md,
            height: t.icons.md,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation(c.primary),
              backgroundColor: c.bg,
            ),
          ),
          SizedBox(width: t.spacing.sm),
          Expanded(
            child: Text(
              '\u6b63\u5728\u786e\u8ba4\u652f\u4ed8...',
              style: t.typography.body.copyWith(color: c.text, fontWeight: FontWeight.w600),
            ),
          ),
          Text('\u6700\u957f 2 \u5206\u949f', style: t.typography.caption.copyWith(color: c.textMuted)),
        ],
      ),
    );
  }
}
