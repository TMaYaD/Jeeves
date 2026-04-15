import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../database/gtd_database.dart';

/// A single row in the inbox list.
class TodoListItem extends StatelessWidget {
  const TodoListItem({super.key, required this.todo, this.onTap});

  final Todo todo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 12),
              child: Icon(
                Icons.chevron_right,
                color: const Color(0xFF9CA3AF),
                size: 20,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    todo.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '– ${_formatTime(todo.createdAt)}',
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime createdAt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final itemDate = DateTime(createdAt.year, createdAt.month, createdAt.day);

    final time = DateFormat('h:mm a').format(createdAt);

    if (itemDate == today) {
      return 'Today, $time';
    } else if (itemDate == tomorrow) {
      return 'Tomorrow, $time';
    } else if (itemDate.isAfter(today) &&
        itemDate.isBefore(today.add(const Duration(days: 7)))) {
      return '${DateFormat.EEEE().format(createdAt)}, $time';
    } else {
      return '${DateFormat.MMMd().format(createdAt)}, $time';
    }
  }
}
