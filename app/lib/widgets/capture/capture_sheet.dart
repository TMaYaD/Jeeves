/// The global capture sheet (#458) — a modal bottom sheet that drops a raw
/// Capture into the Inbox from any screen.
///
/// It reuses the exact write path the Inbox `QuickAddBar` uses
/// (`inboxNotifierProvider.addCapture`), so a Capture created here is
/// indistinguishable from one typed on the Inbox — `capture_source: 'manual'`,
/// `clarified_at` NULL, a raw **Capture** never an Outcome (ADR-0006).
///
/// The sheet **stays open on submit**: the field clears and refocuses (the
/// QuickAddBar `_submit` pattern) so the user can chain rapid captures, and an
/// inline confirmation row is the affordance that the Capture landed — no
/// snackbar, no navigation away from the screen the user was on. Radii follow
/// the canonical 2/4/6 scale (DESIGN.md): 6px sheet corners, 4px input, 2px
/// button. QuickAddBar's legacy `circular(999)` pill is not propagated.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/inbox_provider.dart';

/// Opens the global [CaptureSheet] as a scroll-controlled modal bottom sheet.
///
/// [isScrollControlled] + the `viewInsets.bottom` padding inside the sheet keep
/// the input above the keyboard. The 6px top corners are the canonical surface
/// radius.
Future<void> showCaptureSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
    ),
    builder: (_) => const CaptureSheet(),
  );
}

/// The body of the capture sheet: a single autofocused input, a submit button,
/// and an inline confirmation row that appears once the user has captured at
/// least one item this session.
class CaptureSheet extends ConsumerStatefulWidget {
  const CaptureSheet({super.key});

  @override
  ConsumerState<CaptureSheet> createState() => _CaptureSheetState();
}

class _CaptureSheetState extends ConsumerState<CaptureSheet> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  bool _isSubmitting = false;

  /// How many Captures this sheet has saved since it opened. Drives the inline
  /// confirmation row — the stay-open flow's confirmation affordance.
  int _capturedCount = 0;

  /// Inline error text shown when a write fails. Never a snackbar.
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    final submittedText = _controller.text;
    final title = submittedText.trim();
    if (title.isEmpty) return;
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      await ref.read(inboxNotifierProvider).addCapture(title);
      if (!mounted) return;
      setState(() {
        // Don't clobber the field if the user kept typing while the write was
        // in flight (mirrors QuickAddBar's guard).
        if (_controller.text == submittedText) {
          _controller.clear();
        }
        _capturedCount++;
      });
      // Refocus so the next thought can be typed immediately — this stay-open
      // refocus is the QuickAddBar rapid-capture pattern.
      _focusNode.requestFocus();
    } catch (e, st) {
      // Detail goes to the console via debugPrint at the callsite that
      // catches (widgets/state_surfaces.dart convention); the inline message
      // below is the user-facing surface — never a raw exception string.
      debugPrint('CaptureSheet: capture write failed: $e\n$st');
      if (!mounted) return;
      setState(() => _error = 'Could not save — try again');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Pad by the keyboard inset so the input is never covered.
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: bottomInset + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Capture',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('capture_sheet_field'),
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  textCapitalization: TextCapitalization.sentences,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: "What's on your mind?",
                    hintStyle: const TextStyle(
                      color: Color(0xFF9CA3AF),
                      fontSize: 16,
                    ),
                    filled: true,
                    fillColor: const Color(0xFFF9FAFB),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide:
                          const BorderSide(color: Color(0xFF2563EB), width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('capture_sheet_submit'),
                onPressed: _isSubmitting ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  minimumSize: const Size(64, 48),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(2)),
                ),
                child: const Text('Add'),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.error_outline,
                    size: 16, color: Color(0xFFDC2626)),
                const SizedBox(width: 6),
                Text(
                  _error!,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFFDC2626)),
                ),
              ],
            ),
          ] else if (_capturedCount > 0) ...[
            const SizedBox(height: 10),
            Row(
              key: const Key('capture_sheet_confirmation'),
              children: [
                const Icon(Icons.check_circle,
                    size: 16, color: Color(0xFF16A34A)),
                const SizedBox(width: 6),
                Text(
                  _capturedCount == 1
                      ? 'Captured to Inbox'
                      : 'Captured to Inbox · $_capturedCount captured',
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF16A34A)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
