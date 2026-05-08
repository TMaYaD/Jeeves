/// Step 5 of the Weekly Review wizard: capture 3–5 objectives for the week.
///
/// Pre-populates fields from the previous review's objectives (synced via
/// preferences). The Finish button is enabled once at least one field has
/// been written.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/periodic_review_provider.dart';

class ObjectivesStep extends ConsumerStatefulWidget {
  const ObjectivesStep({super.key});

  @override
  ConsumerState<ObjectivesStep> createState() => _ObjectivesStepState();
}

class _ObjectivesStepState extends ConsumerState<ObjectivesStep> {
  static const _initialFields = 3;
  static const _maxFields = 5;

  late List<TextEditingController> _controllers;
  bool _initialised = false;

  @override
  void initState() {
    super.initState();
    _controllers =
        List.generate(_initialFields, (_) => TextEditingController());
    // Pick up objectives that were already populated before the widget
    // mounted (e.g., wizard reopened at the Objectives step).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _hydrateFromState(ref.read(periodicReviewProvider).objectives);
    });
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _hydrateFromState(List<String> initial) {
    if (_initialised) return;
    if (initial.isEmpty) return;
    setState(() {
      _initialised = true;
      for (final c in _controllers) {
        c.dispose();
      }
      _controllers = [];
      for (final value in initial.take(_maxFields)) {
        _controllers.add(TextEditingController(text: value));
      }
      while (_controllers.length < _initialFields) {
        _controllers.add(TextEditingController());
      }
    });
  }

  void _push() {
    final values =
        _controllers.map((c) => c.text.trim()).toList(growable: false);
    ref.read(periodicReviewProvider.notifier).setObjectives(values);
  }

  void _addField() {
    if (_controllers.length >= _maxFields) return;
    setState(() => _controllers.add(TextEditingController()));
    _push();
  }

  void _removeField(int index) {
    if (_controllers.length <= _initialFields) return;
    setState(() {
      _controllers[index].dispose();
      _controllers.removeAt(index);
    });
    _push();
  }

  @override
  Widget build(BuildContext context) {
    // Listener fires after build completes, so it's safe to setState/dispose
    // controllers here. Reacts to the late population from _onStepEnter when
    // last-week objectives load after the wizard mounts. The initial value
    // is picked up via the post-frame callback in initState.
    ref.listen<List<String>>(
      periodicReviewProvider.select((s) => s.objectives),
      (_, next) => _hydrateFromState(next),
    );

    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        const Text(
          'Set your focus for the week',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A2E),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Pick three to five objectives. They\'ll show up next week as a starting point.',
          style: TextStyle(fontSize: 13, color: Colors.grey[500]),
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < _controllers.length; i++) ...[
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: Key('objective_field_$i'),
                  controller: _controllers[i],
                  onChanged: (_) => _push(),
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Objective ${i + 1}',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              if (i >= _initialFields) ...[
                const SizedBox(width: 4),
                IconButton(
                  key: Key('objective_remove_$i'),
                  tooltip: 'Remove objective',
                  icon: const Icon(Icons.close,
                      size: 18, color: Color(0xFF9CA3AF)),
                  onPressed: () => _removeField(i),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
        ],
        if (_controllers.length < _maxFields)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('objective_add'),
              onPressed: _addField,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add another'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF059669),
              ),
            ),
          ),
      ],
    );
  }
}
