/// Step 1 of the Weekly Review wizard: capture anything on the user's mind
/// to the inbox. Each submission inserts an unclarified todo and bumps the
/// in-session counter so the summary can show how many items were captured.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/inbox_provider.dart';
import '../../../providers/periodic_review_provider.dart';

class BrainDumpStep extends ConsumerStatefulWidget {
  const BrainDumpStep({super.key});

  @override
  ConsumerState<BrainDumpStep> createState() => _BrainDumpStepState();
}

class _BrainDumpStepState extends ConsumerState<BrainDumpStep> {
  final _controller = TextEditingController();
  final _addedTitles = <String>[];
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final title = _controller.text.trim();
    if (title.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    try {
      await ref.read(inboxNotifierProvider).addTodo(title);
      ref.read(periodicReviewProvider.notifier).recordBrainDumpItem();
      if (!mounted) return;
      setState(() {
        _addedTitles.add(title);
        _controller.clear();
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final added = ref.watch(
        periodicReviewProvider.select((s) => s.brainDumpAdded));

    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        const Text(
          'What\'s on your mind?',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A2E),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Capture anything that needs attention. Clarify it later.',
          style: TextStyle(fontSize: 13, color: Colors.grey[500]),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const Key('brain_dump_input'),
                controller: _controller,
                onSubmitted: (_) => _add(),
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'e.g. Email Sam about Q3 planning',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('brain_dump_add'),
              onPressed: _submitting ? null : _add,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF059669),
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 14),
              ),
              child: const Text('Add'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '$added captured',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.grey[500],
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 8),
        if (_addedTitles.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF9FAFB),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Text(
              'Nothing captured yet — add something or tap Next to skip.',
              style: TextStyle(fontSize: 13, color: Colors.grey[500]),
            ),
          )
        else
          for (final t in _addedTitles)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check, size: 16, color: Color(0xFF059669)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t,
                      style: const TextStyle(
                          fontSize: 14, color: Color(0xFF374151)),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
