/// The one-line banner at the top of a Habit's detail: a Jeeves line over the
/// facts. It swipes away and has no close button, like the Nudge Banner.
library;

import 'package:flutter/material.dart';

import 'habit_copy.dart';

/// A Habit flash banner showing [text].
class HabitFlashBanner extends StatelessWidget {
  const HabitFlashBanner({
    super.key,
    required this.text,
    required this.onDismissed,
  });

  final HabitFlashText text;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey('flash-${text.line}-${text.facts}'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => onDismissed(),
      child: Container(
        key: const Key('habit_flash_banner'),
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text.line,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSecondaryContainer)),
            if (text.facts.isNotEmpty)
              Text(text.facts,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSecondaryContainer)),
          ],
        ),
      ),
    );
  }
}
