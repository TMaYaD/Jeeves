/// The "Replace current action?" confirmation sheet (ADR-0004 story 5).
///
/// Shared by the Outcome detail Plan section and every re-clarification surface
/// that promotes a planned Action *over an existing current one* (issue #723),
/// so a replace is never a silent supersede — it always routes through this
/// confirm.
///
/// Returns `true` when the user confirms the replace, `false` on dismissal
/// (barrier tap / back). It performs **no write**: the caller owns the
/// supersede-and-promote, because the error semantics differ per caller — the
/// detail Plan fires-and-forgets (`.ignore()`), while
/// [ProcessToHandlers._nextWithDialog] awaits inside its own write boundary so
/// a failure surfaces as the write-failed snackbar.
library;

import 'package:flutter/material.dart';

const _muted = Color(0xFF9CA3AF);
const _ink = Color(0xFF1F2937);

/// Floats the replace confirmation for a current Action ([currentText]) about
/// to be superseded by a promoted planned one ([newText]).
Future<bool> showReplaceCurrentActionSheet(
  BuildContext context, {
  required String currentText,
  required String newText,
}) async {
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.white,
    // Long Actions wrap to several lines each; let the sheet grow and scroll
    // instead of clipping the confirm button under the default height cap.
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Replace current action?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              _sheetLine('Current', currentText, _muted),
              const SizedBox(height: 8),
              _sheetLine('New', newText, _ink),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('plan_replace_confirm'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Replace current action'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return confirmed ?? false;
}

Widget _sheetLine(String label, String text, Color color) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
            color: _muted,
          ),
        ),
        const SizedBox(height: 2),
        Text(text, style: TextStyle(fontSize: 15, color: color)),
      ],
    );
