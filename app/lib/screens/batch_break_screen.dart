import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/clock_provider.dart';
import '../providers/focus_settings_provider.dart';

/// The one Break after the last member of an accepted small-task batch.
///
/// Held in screen state only: Done has already closed the member's TimeLog, so
/// there is nothing to record this Break on. It is not stored or synced and
/// does not survive a restart. "End break", or the countdown running out,
/// pops back to the Focus list underneath.
class BatchBreakScreen extends ConsumerStatefulWidget {
  const BatchBreakScreen({super.key});

  @override
  ConsumerState<BatchBreakScreen> createState() => _BatchBreakScreenState();
}

class _BatchBreakScreenState extends ConsumerState<BatchBreakScreen> {
  late final DateTime _breakEndsAtUtc;
  Timer? _tick;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    final now = ref.read(clockProvider)().toUtc();
    final minutes = ref.read(focusSettingsProvider).breakDurationMinutes;
    _breakEndsAtUtc = now.add(Duration(minutes: minutes));
    _remaining = _breakEndsAtUtc.difference(now);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _update());
  }

  void _update() {
    final left =
        _breakEndsAtUtc.difference(ref.read(clockProvider)().toUtc());
    if (left <= Duration.zero) {
      _end();
    } else {
      setState(() => _remaining = left);
    }
  }

  void _end() {
    _tick?.cancel();
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final minutes = _remaining.inMinutes;
    final seconds = _remaining.inSeconds % 60;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Break', style: TextStyle(fontSize: 20)),
              const SizedBox(height: 12),
              Text(
                '${minutes.toString().padLeft(2, '0')}:'
                '${seconds.toString().padLeft(2, '0')}',
                key: const Key('batch-break-countdown'),
                style: const TextStyle(
                  fontSize: 56,
                  color: Color(0xFF10B981),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                key: const Key('batch-break-end'),
                onPressed: _end,
                child: const Text('End break'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
