/// Shared per-item card UI used by the Weekly Review wizard's list-driven
/// steps (Waiting For, Projects, Someday/Maybe). The card renders the
/// item's metadata; routing actions are slotted in via a [ProcessToHandlers]
/// child so callsites only configure presentation (`include`, `except`,
/// `labels`) rather than re-implementing the action bar.
library;

import 'package:flutter/material.dart';

import '../../../database/gtd_database.dart';
import '../../../widgets/process_to_handlers.dart';

class ReviewItemCard extends StatelessWidget {
  const ReviewItemCard({
    super.key,
    required this.todo,
    required this.headline,
    required this.process,
    this.subtext,
    this.personTags = const [],
  });

  final Todo todo;
  final String headline;

  /// Configured action bar. Callsites build a [ProcessToHandlers] with the
  /// per-step `include` / `except` / `labels` and an `onAfterRoute` that
  /// records the routing in wizard state.
  final ProcessToHandlers process;

  /// Free-form subtext rendered between the title and the notes — used by
  /// the Next Actions step to surface the persisted `next_action_text`.
  final String? subtext;

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
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFECFDF5),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFD1FAE5)),
          ),
          child: Row(
            children: [
              const Icon(Icons.refresh, size: 18, color: Color(0xFF059669)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  headline,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF065F46),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
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
              if (subtext != null && subtext!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2, right: 6),
                      child: Icon(Icons.arrow_forward,
                          size: 14, color: Color(0xFF2563EB)),
                    ),
                    Expanded(
                      child: Text(
                        subtext!,
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
            ],
          ),
        ),
        const SizedBox(height: 24),
        process,
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
          const Icon(Icons.person_outlined,
              size: 12, color: Color(0xFF7C3AED)),
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

class ReviewLoadError extends StatelessWidget {
  const ReviewLoadError({
    super.key,
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 56, color: Colors.red[300]),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.grey[800],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class ReviewEmptyState extends StatelessWidget {
  const ReviewEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }
}
