/// The three non-data surfaces every provider-bound screen can land on:
/// loading, error, and nothing-to-show.
///
/// They live here rather than inside [AsyncList] because a list with no rows
/// and a single-row surface whose subject is gone are the same thing to the
/// user — "there is nothing here" — and must look the same. [AsyncList] and
/// [AsyncSubject] are the two builders that render them; neither owns the
/// visual contract.
///
/// Nothing here interprets *why* a surface is showing. In particular the
/// missing/empty surface says nothing about deletes, devices or replication:
/// the UI's contract is with the local Drift row, and "the row is not there"
/// is the whole signal it has (ARCHITECTURE.md § Sync Engine).
library;

import 'package:flutter/material.dart';

const _titleGray = Color(0xFF6B7280);
const _subtitleGray = Color(0xFF9CA3AF);
const _iconGray = Color(0xFFD1D5DB);

/// Shown when a provider fails.
///
/// Never renders the exception: raw error text is not user-facing copy. The
/// detail goes to the console via [debugPrint] at the callsite that catches
/// it, so a developer can still see it.
class ErrorSurface extends StatelessWidget {
  const ErrorSurface({super.key});

  /// Key every error surface carries, so tests can assert "errored" without
  /// coupling to the copy.
  static const surfaceKey = Key('state_surface_error');

  @override
  Widget build(BuildContext context) {
    return const Center(
      key: surfaceKey,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          'Something went wrong. Please try again.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _subtitleGray),
        ),
      ),
    );
  }
}

/// Shown when a provider has answered and there is nothing to show — an empty
/// list, or a single-row subject whose row is gone.
///
/// [cta] is the way out. A surface the user cannot leave is a dead end, so
/// every callsite that can be reached with no route out of its own supplies
/// one.
class EmptySurface extends StatelessWidget {
  const EmptySurface({
    super.key,
    required this.title,
    this.icon,
    this.subtitle,
    this.cta,
  });

  final String title;
  final IconData? icon;
  final String? subtitle;
  final Widget? cta;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 48, color: _iconGray),
              const SizedBox(height: 12),
            ],
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _titleGray),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _subtitleGray, fontSize: 13),
              ),
            ],
            if (cta != null) ...[
              const SizedBox(height: 16),
              cta!,
            ],
          ],
        ),
      ),
    );
  }
}

/// The canonical loading surface. A spinner means *only* "not answered yet" —
/// once local storage has answered, the screen owes the user either data, an
/// [ErrorSurface] or an [EmptySurface].
class LoadingSurface extends StatelessWidget {
  const LoadingSurface({super.key});

  static const surfaceKey = Key('state_surface_loading');

  @override
  Widget build(BuildContext context) {
    return const Center(
      key: surfaceKey,
      child: CircularProgressIndicator(),
    );
  }
}
