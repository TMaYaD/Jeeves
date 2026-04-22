import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/focus_session_provider.dart';

/// Displays a Jeeves-flavoured elapsed-time reminder sourced from
/// [focusModeProvider]. Updates every minute; bucketed to 5-min accuracy
/// under 15 min, 15-min accuracy up to 2 h, 30-min accuracy beyond.
/// Returns [SizedBox.shrink] when elapsed < 5 min and not paused.
class ElapsedTimerWidget extends ConsumerStatefulWidget {
  const ElapsedTimerWidget({super.key, this.style});

  final TextStyle? style;

  @override
  ConsumerState<ElapsedTimerWidget> createState() => _ElapsedTimerWidgetState();

  /// Returns the Jeeves-flavoured phrase for [elapsed].
  /// [isPaused] appends a pause suffix when [elapsed] is non-trivial,
  /// or returns a standalone paused phrase when elapsed < 5 min.
  static String jeevesPhrase(Duration elapsed, {bool isPaused = false}) {
    final m = elapsed.inMinutes;
    String phrase;

    if (m < 5) {
      phrase = '';
    } else if (m < 15) {
      // 5-min buckets: 5, 10
      const map = {
        5: 'A trifling five minutes thus far, sir.',
        10: 'Some ten minutes have elapsed, sir.',
      };
      phrase = map[(m ~/ 5) * 5] ?? '';
    } else if (m < 120) {
      // 15-min buckets: 15 … 105
      const map = {
        15: 'A quarter-hour has passed, sir.',
        30: 'Half an hour, if I may note, sir.',
        45: 'Three-quarters of an hour, sir.',
        60: 'An hour has elapsed, sir.',
        75: 'An hour and a quarter have passed, sir, if I may say so.',
        90: 'An hour and a half, sir.',
        105: 'An hour and three-quarters, sir, if you will permit the observation.',
      };
      phrase = map[(m ~/ 15) * 15] ?? map[105]!;
    } else {
      // 30-min buckets: 120, 150, 180 …
      const map = {
        120: 'Two hours have elapsed, sir. One ventures to suggest a brief respite.',
        150: 'Two and a half hours on the matter, sir. One ventures to suggest a brief respite.',
        180: 'Three hours, sir. I feel it my duty to gently insist on a brief respite.',
        210: 'Three and a half hours, sir. I feel it my duty to gently insist on a brief respite.',
        240: 'Four hours, sir. Bertram, really.',
      };
      final bucket = (m ~/ 30) * 30;
      phrase = map[bucket] ?? map[240]!;
    }

    if (isPaused && phrase.isNotEmpty) {
      return '$phrase (Paused.)';
    }
    if (isPaused) return 'Paused, sir.';
    return phrase;
  }
}

class _ElapsedTimerWidgetState extends ConsumerState<ElapsedTimerWidget> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focusState = ref.watch(focusModeProvider);
    final phrase = ElapsedTimerWidget.jeevesPhrase(
      focusState.elapsed,
      isPaused: focusState.isPaused,
    );

    if (phrase.isEmpty) return const SizedBox.shrink();

    return Text(
      phrase,
      textAlign: TextAlign.center,
      style: widget.style ??
          const TextStyle(
            fontSize: 13,
            fontStyle: FontStyle.italic,
            color: Color(0xFF9CA3AF),
            height: 1.4,
          ),
    );
  }
}
