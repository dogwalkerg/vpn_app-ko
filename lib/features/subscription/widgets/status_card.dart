// lib/features/subscription/widgets/status_card.dart
import 'package:flutter/material.dart';
import 'package:vpn_app/core/extensions/context_ext.dart';

Color subscriptionHighlightBackground(BuildContext context) {
  final overlay = Theme.of(context).brightness == Brightness.dark
      ? const Color(0x55F59E42)
      : const Color(0x38F59E42);
  return Color.alphaBlend(overlay, context.colors.bgLight);
}

Color subscriptionHighlightBorder(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFF2A65A)
    : const Color(0xFFE2A054);

class StatusCard extends StatelessWidget {
  final String statusText;
  final String periodText;
  final Color statusColor;
  final bool highlighted;

  const StatusCard({
    super.key,
    required this.statusText,
    required this.periodText,
    required this.statusColor,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.tokens;

    return Container(
      padding: t.spacing.all(t.spacing.md),
      decoration: BoxDecoration(
        color: highlighted
            ? subscriptionHighlightBackground(context)
            : c.bgLight,
        borderRadius: t.radii.brLg,
        boxShadow: t.shadows.z1,
        border: Border.all(
          color: highlighted
              ? subscriptionHighlightBorder(context)
              : c.borderMuted,
          width: highlighted ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(statusText, style: t.typography.h2.copyWith(color: statusColor)),
          SizedBox(height: t.spacing.xs),
          Text(
            periodText,
            style: t.typography.body.copyWith(color: c.textMuted),
          ),
        ],
      ),
    );
  }
}
