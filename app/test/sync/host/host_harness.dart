/// A device with a sync host and no op log: the shape every device has after the
/// host exists and before any plugin is attached.
library;

import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/host/change.dart';
import 'package:jeeves/sync/host/hosted_capture.dart';
import 'package:jeeves/sync/host/sync_host.dart';
import 'package:jeeves/sync/host/sync_host_service.dart';
import 'package:jeeves/sync/sync_database.dart';

/// A manually advanced wall clock shared by one device's stores.
class WallClock {
  WallClock([this.nowMs = 1700000000000]);
  int nowMs;
  void advance([int milliseconds = 1000]) => nowMs += milliseconds;
}

class HostDevice {
  HostDevice._(this.label, this.wall, this.domain, this.sync, this.capture, this.clock);

  final String label;
  final WallClock wall;
  final GtdDatabase domain;
  final SyncDatabase sync;
  final HostedDomainOpCapture capture;
  final HlcClock clock;
  SyncHostService? host;

  /// Open both stores over [directory] files, or in memory when null. The host is
  /// built but **not** started or attached — [startHost] does that, so a test can
  /// write before it exists.
  static HostDevice open(
    String label, {
    Directory? directory,
    WallClock? wall,
  }) {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final wallClock = wall ?? WallClock();
    final clock = HlcClock(memberIdHex: '0' * 32, nowMs: () => wallClock.nowMs);
    final capture = HostedDomainOpCapture(clock: clock);
    final domain = GtdDatabase(
      directory == null
          ? NativeDatabase.memory()
          : NativeDatabase(File('${directory.path}/$label-domain.sqlite')),
      opCapture: capture,
    );
    final sync = SyncDatabase(
      directory == null
          ? NativeDatabase.memory()
          : NativeDatabase(File('${directory.path}/$label-sync.sqlite')),
    );
    return HostDevice._(label, wallClock, domain, sync, capture, clock);
  }

  Future<SyncHostService> startHost() async {
    final built = SyncHostService(sync: sync, domain: domain, clock: clock);
    await built.start();
    capture.attach(built);
    host = built;
    return built;
  }

  Future<void> close() async {
    capture.detach();
    await domain.close();
    await sync.close();
  }
}

/// A plugin whose medium is a shared in-memory list: [deliver] appends to it,
/// [pull] applies what other devices appended.
class RelayPlugin implements SyncPlugin {
  RelayPlugin(this.id, this.relay);

  @override
  final String id;
  final List<({String origin, Change change})> relay;

  /// A device label per instance, so a pull skips the device's own entries.
  String origin = '';
  late SyncHost host;
  int _pulled = 0;

  /// When set, [deliver] takes the changes but acknowledges only this many.
  int? acknowledgeAtMost;

  /// When true, [deliver] throws (the medium is down).
  bool failing = false;

  /// Every batch handed to [deliver], for assertions about redelivery.
  final List<List<SequencedChange>> deliveries = [];

  @override
  Future<void> start(SyncHost host) async => this.host = host;

  @override
  Future<void> stop() async {}

  @override
  Stream<PluginHealth> get health => const Stream.empty();

  @override
  Future<int> deliver(List<SequencedChange> changes) async {
    deliveries.add(changes);
    if (failing) throw StateError('medium down');
    final take = acknowledgeAtMost == null
        ? changes
        : changes.take(acknowledgeAtMost!).toList();
    for (final sequenced in take) {
      relay.add((origin: origin, change: sequenced.change));
    }
    return take.isEmpty ? 0 : take.last.sequence;
  }

  /// Apply everything other devices put on the relay since the last pull.
  Future<void> pull() async {
    final fresh = relay.skip(_pulled).toList();
    _pulled = relay.length;
    await host.applyRemote(
      id,
      [for (final entry in fresh) if (entry.origin != origin) entry.change],
    );
  }
}
