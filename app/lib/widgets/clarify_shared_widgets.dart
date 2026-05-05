/// Shared UI widgets for the inbox clarification flow.
///
/// Used by both the planning wizard's [InboxClarificationStep] (via
/// _ClarifyCard) and the standalone [InboxClarifyScreen] so the two surfaces
/// stay visually identical without duplicating code.
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
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 18, color: enabled ? color : color.withValues(alpha: 0.38)),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: enabled ? 0.4 : 0.2)),
        alignment: Alignment.centerLeft,
        minimumSize: const Size.fromHeight(44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
