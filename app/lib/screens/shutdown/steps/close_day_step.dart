/// Final step of the shutdown ritual: moon-rise animation, Jeeves phrase, and
/// the terminal "Close Day" button. Tapping the button commits dispositions,
/// fades the screen to black, and exits the app.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/evening_shutdown_provider.dart';
import '../../../services/platform_helper.dart'
    if (dart.library.io) '../../../services/platform_helper_io.dart';

class CloseDayStep extends ConsumerStatefulWidget {
  const CloseDayStep({super.key});

  @override
  ConsumerState<CloseDayStep> createState() => _CloseDayStepState();
}

class _CloseDayStepState extends ConsumerState<CloseDayStep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _slideY;
  late final Animation<double> _fade;
  bool _showButton = false;
  bool _fadingOut = false;
  bool _closing = false;

  static const _phrases = [
    'Another day superbly managed, sir. Pleasant dreams.',
    'Capital effort today, sir. I shall stand down for the evening.',
    'The books are balanced and all tasks accounted for, sir. Good night.',
    'Rest well, sir. Tomorrow\'s battles shall wait until morning.',
    'Everything is in order, sir. I shall dim the lights.',
    'A productive day by any measure, sir. Sleep well.',
  ];

  late final String _phrase;

  @override
  void initState() {
    super.initState();
    _phrase = _phrases[Random().nextInt(_phrases.length)];
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _slideY = Tween<double>(begin: 64, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _fade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );
    _controller.forward().then((_) {
      if (mounted) setState(() => _showButton = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onCloseDay() async {
    if (_closing) return;
    setState(() => _closing = true);
    await ref.read(eveningShutdownProvider.notifier).closeDay();
    if (!mounted) return;
    setState(() => _fadingOut = true);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF0D1B2A),
      child: AnimatedOpacity(
        opacity: _fadingOut ? 0.0 : 1.0,
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeIn,
        onEnd: () {
          if (!_fadingOut || !mounted) return;
          closeApp();
        },
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 0, 40, 32),
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: AnimatedBuilder(
                      animation: _controller,
                      builder: (context, _) {
                        return Opacity(
                          opacity: _fade.value,
                          child: Transform.translate(
                            offset: Offset(0, _slideY.value),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.nightlight_round,
                                  size: 88,
                                  color: Color(0xFFE2C97E),
                                ),
                                const SizedBox(height: 36),
                                Text(
                                  _phrase,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w300,
                                    fontStyle: FontStyle.italic,
                                    height: 1.6,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                // Render the button continuously so the moon doesn't shift
                // when it appears; fade in via opacity instead of swapping.
                SizedBox(
                  width: double.infinity,
                  child: AnimatedOpacity(
                    opacity: _showButton ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOut,
                    child: IgnorePointer(
                      ignoring: !_showButton,
                      child: FilledButton.icon(
                        onPressed: _closing ? null : _onCloseDay,
                        icon: const Icon(Icons.nightlight_round, size: 20),
                        label: const Text(
                          'Close Day',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFE2C97E),
                          foregroundColor: const Color(0xFF0D1B2A),
                          disabledBackgroundColor:
                              const Color(0xFFE2C97E).withAlpha(120),
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
