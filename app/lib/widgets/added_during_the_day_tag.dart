import 'package:flutter/material.dart';

/// The mark on a Plan entry the user added during Execution rather than chose
/// in Planning (issue #700). Text carries the state, not colour, so it reads
/// the same without colour vision. "Added during the day" is the daily-cadence
/// copy for an entry added during Execution.
class AddedDuringTheDayTag extends StatelessWidget {
  const AddedDuringTheDayTag({super.key});

  static const label = 'Added during the day';

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: Color(0xFF4B5563),
        ),
      ),
    );
  }
}
