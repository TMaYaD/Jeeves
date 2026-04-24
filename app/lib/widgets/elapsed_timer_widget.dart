import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/focus_session_provider.dart';
import '../providers/sprint_timer_provider.dart';

/// Displays a Jeeves-flavoured elapsed-time reminder sourced from
/// [focusModeProvider]. Updates every minute; bucketed to 5-min accuracy
/// under 15 min, 15-min accuracy up to 2 h, 30-min accuracy beyond.
class ElapsedTimerWidget extends ConsumerStatefulWidget {
  const ElapsedTimerWidget({super.key, this.style});

  final TextStyle? style;

  @override
  ConsumerState<ElapsedTimerWidget> createState() => _ElapsedTimerWidgetState();

  static final _random = Random();

  /// Returns the Jeeves-flavoured phrase for [elapsed].
  ///
  /// [isPaused] appends a pause suffix.
  ///
  /// [seed] makes template selection deterministic. The widget seeds from
  /// the active task id plus the current bucket so the phrase is stable
  /// per-task-per-bucket and doesn't flip mid-glance on rebuilds.
  /// Returns a Jeeves-flavoured phrase when the sprint or break time has elapsed
  /// and the user has not yet transitioned (overtime / waiting state).
  static String jeevesOvertimePhrase({required bool isFocus, int? seed}) {
    final pool = isFocus
        ? const [
            'The sprint is done, sir. A break is in order.',
            'Time is up, sir. One insists on a brief respite.',
            'Your sprint has concluded. Might one suggest the pause button?',
            'The work shall keep, sir. A rest is warranted.',
          ]
        : const [
            'The break is over, sir. Whenever you are ready.',
            'One trusts you are sufficiently refreshed, sir.',
            'Back to the grindstone at your convenience, sir.',
            'The task awaits your return, sir.',
          ];
    final rng = seed == null ? _random : Random(seed);
    return pool[rng.nextInt(pool.length)];
  }

  /// Returns a Jeeves-flavoured phrase shown when < 5 min remain in a sprint.
  static String jeevesSprintNearEndPhrase(Duration remaining, {int? seed}) {
    final m = remaining.inMinutes;
    final String timeStr;
    if (remaining.inSeconds <= 10) {
      timeStr = 'moments';
    } else if (m == 0) {
      timeStr = 'less than a minute';
    } else if (m == 1) {
      timeStr = 'one minute';
    } else {
      timeStr = '$m minutes';
    }

    final pool = [
      'Nearly there, sir. {t} remaining — a break will be in order.',
      'The sprint draws to a close, sir. {t} to go.',
      'Almost done, sir — {t} remaining. One shall insist on a rest.',
      '{t} left, sir. One ventures to suggest a reprieve is imminent.',
      'One more push, sir. {t} remains.',
    ];
    final rng = seed == null ? _random : Random(seed);
    return pool[rng.nextInt(pool.length)].replaceAll('{t}', timeStr);
  }

  /// Returns a Jeeves-flavoured phrase for an active break with [remaining] time.
  static String jeevesBreakPhrase(Duration remaining, {int? seed}) {
    final m = remaining.inMinutes;
    final String timeStr;
    if (remaining.inSeconds <= 10) {
      timeStr = 'moments';
    } else if (m == 0) {
      timeStr = 'less than a minute';
    } else if (m == 1) {
      timeStr = 'one minute';
    } else {
      timeStr = '$m minutes';
    }

    final pool = [
      'A spot of tea is in order, sir. {t} remaining.',
      'Perhaps a brief constitutional, sir. {t} remains.',
      'Stretch the legs, sir — {t} remains.',
      'Step away from the desk, sir. {t} of rest remain.',
      'One insists on tea, sir. {t} remaining.',
      'A brisk walk would serve you well, sir. {t} remains.',
      'The kettle awaits, sir. {t} of respite remain.',
    ];
    final rng = seed == null ? _random : Random(seed);
    return pool[rng.nextInt(pool.length)].replaceAll('{t}', timeStr);
  }

  /// Returns a Jeeves-flavoured phrase for the final 60 seconds of a break.
  static String jeevesBreakEndingPhrase({int? seed}) {
    final pool = [
      'The task awaits, sir. Time to return.',
      'Back to the grindstone, sir.',
      "One's rest is concluded, sir. The work calls.",
      'Recharged and ready, sir? The task awaits.',
      "Break's end, sir. Onward.",
    ];
    final rng = seed == null ? _random : Random(seed);
    return pool[rng.nextInt(pool.length)];
  }

  static String jeevesPhrase(Duration elapsed,
      {bool isPaused = false, int? seed, bool suppressRest = false}) {
    final m = elapsed.inMinutes;
    final duration = m < 5 ? '' : _describeDuration(m);
    final template = isPaused
        ? _pickPausedTemplate(m, seed: seed)
        : _pickTemplate(m, seed: seed, suppressRest: suppressRest);
    var phrase = template.replaceAll('{d}', duration);

    // Jeeves does not begin sentences with lowercase letters.
    if (phrase.isNotEmpty) {
      phrase = phrase[0].toUpperCase() + phrase.substring(1);
    }
    return phrase;
  }

  /// Jeeves-voice utterance for a paused session. Replaces the active
  /// commentary entirely — Jeeves doesn't speak parentheticals.
  /// All templates carry a `rest`/`reprieve`/`abeyance` marker so callers
  /// can recognise paused-mode prose without exact-string matching.
  static String _pickPausedTemplate(int m, {int? seed}) {
    late final List<String> pool;
    if (m < 5) {
      pool = const [
        'Barely begun, sir, and already at rest.',
        'Scarcely underway, sir; at rest already.',
        'A reprieve before we have properly begun, sir.',
      ];
    } else {
      pool = const [
        '{d} on the matter, sir; we are at rest.',
        '{d} thus far, sir, and now at rest.',
        '{d}, sir. The matter rests, with your leave.',
        '{d} elapsed, sir; held in abeyance.',
        'A reprieve at {d}, sir.',
        'After {d}, sir, a brief reprieve.',
      ];
    }
    final rng = seed == null ? _random : Random(seed);
    return pool[rng.nextInt(pool.length)];
  }

  /// Renders the duration itself in period-appropriate prose.
  static String _describeDuration(int m) {
    if (m < 15) {
      // 5-min buckets: 5, 10
      return {5: 'five minutes', 10: 'ten minutes'}[(m ~/ 5) * 5]!;
    }
    if (m < 120) {
      // 15-min buckets
      return const {
        15: 'a quarter-hour',
        30: 'half an hour',
        45: 'three-quarters of an hour',
        60: 'an hour',
        75: 'an hour and a quarter',
        90: 'an hour and a half',
        105: 'an hour and three-quarters',
      }[(m ~/ 15) * 15]!;
    }
    // 30-min buckets, capped at a sensible maximum
    final bucket = (m ~/ 30) * 30;
    final hours = bucket ~/ 60;
    final halfWord = bucket % 60 == 30 ? ' and a half' : '';
    final hoursWord = _numberWord(hours);
    return '$hoursWord$halfWord hours';
  }

  static String _numberWord(int n) =>
      const {
        2: 'two', 3: 'three', 4: 'four', 5: 'five', 6: 'six',
        7: 'seven', 8: 'eight', 9: 'nine', 10: 'ten',
      }[n] ??
      '$n';

  /// Picks a template whose tone matches the elapsed time. Deterministic
  /// when [seed] is supplied; otherwise draws from a shared [Random].
  /// When [suppressRest] is true, "perhaps a break" suggestions are omitted.
  static String _pickTemplate(int m, {int? seed, bool suppressRest = false}) {
    late final List<String> pool;

    if (m < 5) {
      pool = const [
        'Just begun, sir.',
        'Underway, sir.',
        'We have commenced, sir.',
      ];
    } else if (m < 15) {
      pool = const [
        'A trifling {d} thus far, sir.',
        'Merely {d}, sir.',
        'Some {d} in, sir.',
      ];
    } else if (m < 60) {
      pool = const [
        '{d} has passed, sir.',
        '{d}, if I may note, sir.',
        'Some {d} thus far, sir.',
        '{d} on the matter, sir.',
      ];
    } else if (m < 120) {
      pool = const [
        '{d} elapsed, sir.',
        '{d}, sir, if you will permit the observation.',
        '{d} on the task, sir.',
        'A full {d}, sir.',
      ];
    } else if (m < 180) {
      pool = suppressRest
          ? const [
              '{d} elapsed, sir.',
              '{d} on the task, sir.',
              'A full {d}, sir.',
            ]
          : const [
              '{d} on the matter, sir. One ventures to suggest a brief respite.',
              "{d} elapsed, sir. Perhaps a moment's pause would not go amiss.",
              '{d} already, sir. Might one suggest a brief interval?',
            ];
    } else if (m < 240) {
      pool = suppressRest
          ? const [
              '{d} elapsed, sir.',
              '{d} on the task, sir.',
            ]
          : const [
              '{d}, sir. I feel it my duty to gently insist on a respite.',
              '{d} at the grindstone, sir. One really must protest.',
              '{d}, sir. One must, regrettably, insist on a pause.',
            ];
    } else {
      pool = suppressRest
          ? const [
              '{d} elapsed, sir.',
              '{d} at the task, sir.',
            ]
          : const [
              '{d}, sir. I really must speak plainly: do stop.',
              '{d} at this, sir. This has gone quite far enough.',
              '{d}, sir. I beg you — put the matter down.',
            ];
    }

    final rng = seed == null ? _random : Random(seed);
    return pool[rng.nextInt(pool.length)];
  }
}

class _ElapsedTimerWidgetState extends ConsumerState<ElapsedTimerWidget>
    with SingleTickerProviderStateMixin {
  // Parchment palette — "the butler observes, no action required".
  // Urgency (amber, red) is reserved for Jeeves utterances that demand action.
  static const _bg = Color(0xFFF7F2E7); // parchment
  static const _accent = Color(0xFF8B6B3E); // warm brown
  static const _ink = Color(0xFF4A3B28); // dark brown

  Timer? _ticker;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focusState = ref.watch(focusModeProvider);
    final sprintState = ref.watch(sprintTimerProvider);

    if (!focusState.isActive) return const SizedBox.shrink();

    // Break overtime — gently insist the user return to work.
    if (sprintState.phase == SprintPhase.breakOvertime) {
      return _buildBanner(
        ElapsedTimerWidget.jeevesOvertimePhrase(
          isFocus: false,
          seed: sprintState.sprintNumber,
        ),
        icon: Icons.self_improvement,
        iconColor: const Color(0xFF10B981),
      );
    }

    // Break countdown — tea and exercise copy.
    if (sprintState.isBreak) {
      final phrase = sprintState.remaining.inSeconds <= 60
          ? ElapsedTimerWidget.jeevesBreakEndingPhrase(
              seed: sprintState.sprintNumber,
            )
          : ElapsedTimerWidget.jeevesBreakPhrase(
              sprintState.remaining,
              seed: sprintState.sprintNumber,
            );
      return _buildBanner(
        phrase,
        icon: Icons.self_improvement,
        iconColor: const Color(0xFF10B981),
      );
    }

    // Focus overtime — insist on a break.
    if (sprintState.phase == SprintPhase.focusOvertime) {
      return _buildBanner(
        ElapsedTimerWidget.jeevesOvertimePhrase(
          isFocus: true,
          seed: sprintState.sprintNumber,
        ),
        icon: Icons.timer_outlined,
        iconColor: const Color(0xFFF59E0B),
      );
    }

    // Sprint near end — suggest the coming break.
    if (sprintState.isFocus && sprintState.remaining.inMinutes < 5) {
      final phrase = ElapsedTimerWidget.jeevesSprintNearEndPhrase(
        sprintState.remaining,
        seed: sprintState.sprintNumber,
      );
      return _buildBanner(
        phrase,
        icon: Icons.timer_outlined,
        iconColor: const Color(0xFF2563EB),
      );
    }

    final m = focusState.elapsed.inMinutes;
    final bucketSize = m < 15 ? 5 : (m < 120 ? 15 : 30);
    final bucket = m ~/ bucketSize;
    final seed = Object.hash(focusState.activeTodoId, bucket, bucketSize);
    final phrase = ElapsedTimerWidget.jeevesPhrase(
      focusState.elapsed,
      isPaused: focusState.isPaused,
      seed: seed,
      suppressRest: sprintState.isPostBreakCooldown,
    );

    if (phrase.isEmpty) return const SizedBox.shrink();
    return _buildBanner(phrase);
  }

  Widget _buildBanner(String phrase,
      {IconData icon = Icons.access_time,
      Color iconColor = _accent}) {
    final voiceStyle = widget.style ??
        const TextStyle(
          fontFamily: 'Manrope',
          fontSize: 20,
          fontStyle: FontStyle.italic,
          fontWeight: FontWeight.w500,
          color: _ink,
          height: 1.35,
          letterSpacing: 0.1,
        );

    return Container(
      decoration: const BoxDecoration(
        color: _bg,
        border: Border(
          top: BorderSide(color: Color(0x228B6B3E)),
          bottom: BorderSide(color: Color(0x228B6B3E)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Row(
          children: [
            ScaleTransition(
              scale: Tween<double>(begin: 0.92, end: 1.08).animate(
                CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
              ),
              child: Icon(icon, size: 24, color: iconColor),
            ),
            const SizedBox(width: 14),
            Expanded(child: Text(phrase, style: voiceStyle)),
          ],
        ),
      ),
    );
  }
}
