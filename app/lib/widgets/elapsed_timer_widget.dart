import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/focus_session_provider.dart';

/// Displays a live elapsed timer (HH:MM:SS) sourced from
/// [focusModeProvider]. Updates every second; frozen while paused.
class ElapsedTimerWidget extends ConsumerStatefulWidget {
  const ElapsedTimerWidget({super.key, this.style});

  final TextStyle? style;

  @override
  ConsumerState<ElapsedTimerWidget> createState() => _ElapsedTimerWidgetState();
}

class _ElapsedTimerWidgetState extends ConsumerState<ElapsedTimerWidget> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
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
    final elapsed = focusState.elapsed;

    final h = elapsed.inHours.toString().padLeft(2, '0');
    final m = (elapsed.inMinutes % 60).toString().padLeft(2, '0');
    final s = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    final display = '$h:$m:$s';

    return Text(
      display,
      style: widget.style ??
          const TextStyle(
            fontSize: 52,
            fontWeight: FontWeight.w300,
            color: Color(0xFF1A1A2E),
            letterSpacing: 2,
          ),
    );
  }
}
