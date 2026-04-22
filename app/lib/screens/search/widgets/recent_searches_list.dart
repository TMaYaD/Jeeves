import 'package:flutter/material.dart';

/// Shows the persisted list of recent searches with swipe-to-dismiss and
/// a "Clear all" action.
class RecentSearchesList extends StatelessWidget {
  const RecentSearchesList({
    super.key,
    required this.searches,
    required this.onTap,
    required this.onRemove,
    required this.onClearAll,
  });

  final List<String> searches;
  final void Function(String query) onTap;
  final void Function(String query) onRemove;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    if (searches.isEmpty) {
      return const Center(
        child: Text(
          'Start typing to search',
          style: TextStyle(color: Color(0xFF9CA3AF)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'RECENT',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: Color(0xFF9CA3AF),
                  ),
                ),
              ),
              TextButton(
                onPressed: onClearAll,
                child: const Text('Clear all', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: searches.length,
            itemBuilder: (context, i) {
              final query = searches[i];
              return Dismissible(
                key: ValueKey(query),
                direction: DismissDirection.endToStart,
                onDismissed: (_) => onRemove(query),
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 16),
                  color: Colors.redAccent,
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                child: ListTile(
                  leading: const Icon(
                    Icons.history,
                    color: Color(0xFF9CA3AF),
                  ),
                  title: Text(query),
                  onTap: () => onTap(query),
                  trailing: IconButton(
                    icon: const Icon(
                      Icons.close,
                      size: 16,
                      color: Color(0xFF9CA3AF),
                    ),
                    onPressed: () => onRemove(query),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
