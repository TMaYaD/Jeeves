/// The op-log replacement for the PowerSync `_SyncIndicator` in the drawer.
///
/// Renders three things and nothing else: **queue depth** (unsent ops),
/// **last-synced** (as a tooltip), and **integrity alarms**. The degraded state
/// is read from `SyncHealth.clean` — a derived getter, so the indicator cannot
/// disagree with the counts it is rendering.
///
/// Not wired into `app_shell.dart` yet: the live app has no running op-log
/// stack to report on until #553 flips the write path and swaps
/// `syncStatusProvider` for a health provider. The dead-letter machinery this
/// replaces does **not** carry over — quarantine plus this surface is its
/// successor, and its removal ships with #556.
library;

import 'package:flutter/material.dart';

import '../sync/sync_health.dart';

class SyncHealthIndicator extends StatelessWidget {
  const SyncHealthIndicator({super.key, required this.stream});

  final Stream<SyncHealth> stream;

  static const Color _idle = Color(0xFF9CA3AF);
  static const Color _healthy = Color(0xFF16A34A);
  static const Color _pending = Color(0xFF2563EB);
  static const Color _alarm = Color(0xFFDC2626);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncHealth>(
      stream: stream,
      builder: (context, snapshot) {
        final health = snapshot.data;
        if (health == null) {
          return const Tooltip(
            message: 'Sync starting',
            child: Icon(Icons.cloud_off_outlined, size: 20, color: _idle),
          );
        }
        return Tooltip(
          message: _tooltip(health),
          child: _badge(health),
        );
      },
    );
  }

  Widget _badge(SyncHealth health) {
    final icon = Icon(_icon(health), size: 20, color: _color(health));
    if (health.pendingOpCount == 0) return icon;
    // Queue depth is the wedged-outbox signal, so it is rendered as a number
    // rather than folded into the icon's colour.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          right: -6,
          top: -4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: _color(health),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${health.pendingOpCount}',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  static IconData _icon(SyncHealth health) {
    if (health.degraded) return Icons.gpp_maybe;
    if (health.pendingOpCount > 0) return Icons.cloud_upload_outlined;
    return health.lastSyncedAt == null ? Icons.cloud_off_outlined : Icons.cloud_done;
  }

  static Color _color(SyncHealth health) {
    if (health.degraded) return _alarm;
    if (health.pendingOpCount > 0) return _pending;
    return health.lastSyncedAt == null ? _idle : _healthy;
  }

  static String _tooltip(SyncHealth health) {
    final parts = <String>[];
    if (health.clean && health.quarantineCount == 0) {
      parts.add('Synced');
    } else {
      if (health.pendingOpCount > 0) {
        parts.add('${health.pendingOpCount} waiting to send');
      }
      if (health.unresolvedAlarmCount > 0) {
        final kinds = health.alarmKinds.toList()..sort();
        parts.add(
          '${health.unresolvedAlarmCount} integrity '
          '${health.unresolvedAlarmCount == 1 ? 'alarm' : 'alarms'}'
          '${kinds.isEmpty ? '' : ' (${kinds.join(', ')})'}',
        );
      }
      if (health.quarantineCount > 0) {
        parts.add('${health.quarantineCount} refused');
      }
      if (parts.isEmpty) parts.add('Synced');
    }
    parts.add(
      health.lastSyncedAt == null
          ? 'Never synced'
          : 'Last synced ${health.lastSyncedAt!.toUtc().toIso8601String()}',
    );
    return parts.join(' · ');
  }
}
