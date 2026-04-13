import 'package:flutter/material.dart';

/// Pinned bottom bar with a text field and an Add button.
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
  bool _isEmpty = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    _isEmpty = widget.controller.text.trim().isEmpty;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final empty = widget.controller.text.trim().isEmpty;
    if (empty != _isEmpty) setState(() => _isEmpty = empty);
  }

  Future<void> _submit() async {
    final title = widget.controller.text.trim();
    if (title.isEmpty) return;
    await widget.onAdd(title);
    widget.controller.clear();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: _focusNode,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  hintText: 'Capture a task…',
                  border: InputBorder.none,
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _isEmpty ? null : _submit,
              style: ElevatedButton.styleFrom(
                shape: const StadiumBorder(),
              ),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }
}
