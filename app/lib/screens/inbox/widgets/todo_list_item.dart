import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../database/gtd_database.dart';

/// A single row in the inbox list.
class TodoListItem extends StatelessWidget {
  const TodoListItem({super.key, required this.todo});

  final Todo todo;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(todo.title),
      subtitle: todo.notes != null ? Text(todo.notes!) : null,
      trailing: Text(
        _relativeTime(todo.createdAt),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  String _relativeTime(DateTime createdAt) {
    final diff = DateTime.now().difference(createdAt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    return DateFormat.MMMd().format(createdAt);
  }
}
