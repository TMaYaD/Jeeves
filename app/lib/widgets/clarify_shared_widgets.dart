/// Shared *field* widgets for the clarification flow — the labels, energy
/// picker and estimate chips both [ClarifyCard] and the standalone
/// [InboxClarifyScreen] render above their action bar.
///
/// Routing buttons are **not** here: those come from [ProcessToHandlers], the
/// single canonical action bar, which owns the writes as well as the copy.
/// [ClarifyDestinationButton] survives for the one affordance that is not a
/// routing verdict — [InboxClarifyScreen]'s Skip. Consolidating it with
/// `ProcessToHandlers`' own button (they are near-identical) is a follow-up.
library;

import 'package:flutter/material.dart';

const _labelGray = Color(0xFF9CA3AF);
const _textGray = Color(0xFF6B7280);
const _borderGray = Color(0xFFD1D5DB);
const _chipBlue = Color(0xFF2563EB);
const _energyLowColor = Color(0xFF16A34A);
const _energyMediumColor = Color(0xFFF59E0B);
const _energyHighColor = Color(0xFFDC2626);

class ClarifyFieldLabel extends StatelessWidget {
  const ClarifyFieldLabel(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
        color: _labelGray,
      ),
    );
  }
}

class ClarifyEnergyPicker extends StatelessWidget {
  const ClarifyEnergyPicker({
    super.key,
    required this.selected,
    required this.onSelect,
  });

  final String? selected;
  final void Function(String?) onSelect;

  static const _levels = [
    ('low', 'Low', _energyLowColor),
    ('medium', 'Medium', _energyMediumColor),
    ('high', 'High', _energyHighColor),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: _levels.map(((String, String, Color) level) {
        final (value, label, color) = level;
        final isSelected = selected == value;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onSelect(isSelected ? null : value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? color.withValues(alpha: 0.1) : Colors.transparent,
                border: Border.all(
                  color: isSelected ? color : _borderGray,
                  width: isSelected ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? color : _textGray,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class ClarifyEstimateChip extends StatelessWidget {
  const ClarifyEstimateChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? _chipBlue : Colors.transparent,
          border: Border.all(
            color: selected ? _chipBlue : _borderGray,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : _textGray,
          ),
        ),
      ),
    );
  }
}

class ClarifyDestinationButton extends StatelessWidget {
  const ClarifyDestinationButton({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.enabled = true,
    this.isPreviouslySelected = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool enabled;

  /// When true, the button shows a stronger border and light background tint
  /// to indicate it was the previously chosen routing for this item.
  final bool isPreviouslySelected;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 18, color: enabled ? color : color.withValues(alpha: 0.38)),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        backgroundColor: isPreviouslySelected ? color.withValues(alpha: 0.08) : null,
        side: BorderSide(
          color: isPreviouslySelected
              ? color
              : color.withValues(alpha: enabled ? 0.4 : 0.2),
          width: isPreviouslySelected ? 2.0 : 1.0,
        ),
        alignment: Alignment.centerLeft,
        minimumSize: const Size.fromHeight(44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

/// What a clarify surface renders once its subject is gone from local storage.
///
/// Deliberately says nothing about *why* it is gone. A clarify surface reads
/// the local row and cannot tell a delete made on this device from one
/// replicated in from another — "the row is no longer there" is the whole
/// signal it has (ARCHITECTURE.md § Sync Engine — the UI's contract is with
/// the local row).
class ClarifySubjectMissing extends StatelessWidget {
  const ClarifySubjectMissing({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('clarify_subject_missing'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.inventory_2_outlined, size: 40, color: _labelGray),
            SizedBox(height: 12),
            Text(
              'This item is no longer here',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Color(0xFF374151),
              ),
            ),
            SizedBox(height: 6),
            Text(
              'It was removed while you had it open, so there is nothing '
              'left to clarify.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: _textGray),
            ),
          ],
        ),
      ),
    );
  }
}
