import 'package:flutter/material.dart';

import '../database/gtd_database.dart';

class OutcomeReviewCard extends StatelessWidget {
  const OutcomeReviewCard({
    super.key,
    required this.todo,
    this.banner,
    required this.actions,
    this.currentActionText,
    this.meta,
    this.personTags = const [],
  });

  final Todo todo;
  final OutcomeReviewBanner? banner;
  final Widget? meta;

  /// Configured action bar. Callsites build a routing widget with the
  /// per-step `include` / `except` / `labels` and an `onAfterRoute` that
  /// records the routing in wizard state.
  final Widget actions;

  /// Current Action rendered between the title and the notes — used by
  /// the Next Actions step to surface the Outcome's current Action.
  final String? currentActionText;

  /// Person tags rendered as small chips above the title. The Waiting For
  /// step passes the delegate(s) attached to the item so reviewers can see
  /// who they're waiting on without leaving the card.
  final List<Tag> personTags;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        if (banner != null) ...[banner!, const SizedBox(height: 16)],
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (personTags.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in personTags)
                      _PersonTagChip(name: tag.name),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              Text(
                todo.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              if (currentActionText != null &&
                  currentActionText!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2, right: 6),
                      child: Icon(
                        Icons.arrow_forward,
                        size: 14,
                        color: Color(0xFF2563EB),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        currentActionText!,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF1D4ED8),
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (todo.notes != null && todo.notes!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  todo.notes!,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF6B7280),
                    height: 1.4,
                  ),
                ),
              ],
              if (meta != null) ...[const SizedBox(height: 8), meta!],
            ],
          ),
        ),
        const SizedBox(height: 24),
        actions,
      ],
    );
  }
}

class _PersonTagChip extends StatelessWidget {
  const _PersonTagChip({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF3E8FF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE9D5FF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.person_outlined, size: 12, color: Color(0xFF7C3AED)),
          const SizedBox(width: 4),
          Text(
            name,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B21A8),
            ),
          ),
        ],
      ),
    );
  }
}

/// The shared ceremony banner; callers select the hint's icon, text and tone.
class OutcomeReviewBanner extends StatelessWidget {
  const OutcomeReviewBanner({
    super.key,
    required this.icon,
    required this.text,
    this.backgroundColor = const Color(0xFFECFDF5),
    this.borderColor = const Color(0xFFD1FAE5),
    this.iconColor = const Color(0xFF059669),
    this.textColor = const Color(0xFF065F46),
  });
  final IconData icon;
  final String text;
  final Color backgroundColor;
  final Color borderColor;
  final Color iconColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: borderColor),
    ),
    child: Row(
      children: [
        Icon(icon, size: 18, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ),
      ],
    ),
  );
}
