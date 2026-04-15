import 'package:flutter/material.dart';

import '../database/gtd_database.dart' show Todo;

/// Picker for selecting a blocking task.
class BlockedByPickerWidget extends StatelessWidget {
  const BlockedByPickerWidget({
    super.key,
    required this.potentialBlockers,
    required this.currentBlockerId,
    required this.onChanged,
  });

  final List<Todo> potentialBlockers;
  final String? currentBlockerId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    // Guard against a stale blocker ID that is no longer in potentialBlockers
    final safeInitialBlockerId = potentialBlockers.any(
      (t) => t.id == currentBlockerId,
    )
        ? currentBlockerId
        : null;

    final title = safeInitialBlockerId == null 
        ? 'None' 
        : potentialBlockers.firstWhere((t) => t.id == safeInitialBlockerId).title;

    return InkWell(
      onTap: () => _showPicker(context, safeInitialBlockerId),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Color(0xFF374151),
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  void _showPicker(BuildContext context, String? safeInitial) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Text('Select Blocker', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              const Divider(color: Color(0xFFF3F4F6)),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                      title: const Text('None', style: TextStyle(color: Color(0xFF374151))),
                      trailing: safeInitial == null ? const Icon(Icons.check, color: Color(0xFF2563EB)) : null,
                      onTap: () {
                        onChanged(null);
                        Navigator.pop(ctx);
                      },
                    ),
                    for (final t in potentialBlockers)
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                        title: Text(t.title, style: const TextStyle(color: Color(0xFF374151))),
                        trailing: safeInitial == t.id ? const Icon(Icons.check, color: Color(0xFF2563EB)) : null,
                        onTap: () {
                          onChanged(t.id);
                          Navigator.pop(ctx);
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
