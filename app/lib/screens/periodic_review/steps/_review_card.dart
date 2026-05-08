/// Shared per-item card and action button widgets used by the Weekly Review
/// wizard's list-driven steps (Waiting For, Projects, Someday/Maybe).
library;

import 'package:flutter/material.dart';

import '../../../database/gtd_database.dart';

class ReviewAction {
  const ReviewAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final Future<void> Function() onTap;
}

class ReviewItemCard extends StatefulWidget {
  const ReviewItemCard({
    super.key,
    required this.todo,
    required this.headline,
    required this.actions,
  });

  final Todo todo;
  final String headline;
  final List<ReviewAction> actions;

  @override
  State<ReviewItemCard> createState() => _ReviewItemCardState();
}

class _ReviewItemCardState extends State<ReviewItemCard> {
  bool _processing = false;

  Future<void> _run(ReviewAction action) async {
    if (_processing) return;
    setState(() => _processing = true);
    try {
      await action.onTap();
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final todo = widget.todo;
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
                  widget.headline,
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
              Text(
                todo.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                ),
              ),
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
        AnimatedOpacity(
          opacity: _processing ? 0.4 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < widget.actions.length; i++) ...[
                _ActionButton(
                  label: widget.actions[i].label,
                  icon: widget.actions[i].icon,
                  color: widget.actions[i].color,
                  enabled: !_processing,
                  onTap: () => _run(widget.actions[i]),
                ),
                if (i < widget.actions.length - 1)
                  const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 18, color: enabled ? color : color.withValues(alpha: 0.38)),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(
          color: color.withValues(alpha: enabled ? 0.4 : 0.2),
        ),
        alignment: Alignment.centerLeft,
        minimumSize: const Size.fromHeight(44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
