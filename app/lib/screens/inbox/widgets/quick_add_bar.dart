import 'package:flutter/material.dart';

/// Pill-shaped input bar for quick inbox capture.
class QuickAddBar extends StatefulWidget {
  const QuickAddBar({
    super.key,
    required this.controller,
    required this.onAdd,
  });

  final TextEditingController controller;
  final Future<void> Function(String title) onAdd;

  @override
  State<QuickAddBar> createState() => _QuickAddBarState();
}

class _QuickAddBarState extends State<QuickAddBar> {
  final _focusNode = FocusNode();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    final submittedText = widget.controller.text;
    final title = submittedText.trim();
    if (title.isEmpty) return;
    setState(() => _isSubmitting = true);
    try {
      await widget.onAdd(title);
      if (!mounted) return;
      if (widget.controller.text == submittedText) {
        widget.controller.clear();
      }
      _focusNode.requestFocus();
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary,
          width: 1.5,
        ),
        color: Colors.white,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focusNode,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                hintText: "What's on your mind?",
                hintStyle: TextStyle(
                  color: Color(0xFF9CA3AF),
                  fontSize: 16,
                ),
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                isDense: true,
              ),
            ),
          ),
          TextButton(
            onPressed: _isSubmitting ? null : _submit,
            child: const Text('Add'),
          ),
          Icon(
            Icons.camera_alt_outlined,
            color: const Color(0xFF4A5568),
            size: 24,
          ),
          const SizedBox(width: 12),
          Icon(
            Icons.mic_none,
            color: const Color(0xFF4A5568),
            size: 24,
          ),
        ],
      ),
    );
  }
}
