/// N simulated devices of one User against one fake server.
library;

import 'dart:typed_data';

import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/merge_strategy.dart';
import 'package:uuid/uuid.dart';

import 'fake_sync_server.dart';
import 'sim_device.dart';

/// The base wall time the fake clock starts at. Fixed so HLCs in failure
/// messages are readable and reproducible.
const int simulationStartWallMs = 1800000000000;

class SimWorkspace {
  SimWorkspace._(this.server, this.clock, this.userId, this.devices);

  static Future<SimWorkspace> create({
    int deviceCount = 2,
    String userId = 'sim-user',
    FakeSyncServer? server,
    FakeClock? clock,
    MergeStrategyRegistry strategies = const MergeStrategyRegistry(),
  }) async {
    final sharedServer = server ?? FakeSyncServer();
    final sharedClock = clock ?? FakeClock(simulationStartWallMs);
    final devices = <SimDevice>[];
    for (var index = 0; index < deviceCount; index++) {
      devices.add(
        await SimDevice.create(
          label: String.fromCharCode('A'.codeUnitAt(0) + index),
          userId: userId,
          server: sharedServer,
          clock: sharedClock,
          strategies: strategies,
          // Deterministic identity: HLC ties break on the member id, so a
          // random one would make the tie-break cases reproduce differently
          // from run to run.
          memberId: const Uuid().v5(jeevesWorkspaceNamespace, 'sim/device/$index'),
          seed: Uint8List.fromList(
            List<int>.generate(32, (byte) => (byte + index * 31 + 1) % 256),
          ),
        ),
      );
    }
    return SimWorkspace._(sharedServer, sharedClock, userId, devices);
  }

  final FakeSyncServer server;
  final FakeClock clock;
  final String userId;
  final List<SimDevice> devices;

  String get workspaceId => implicitWorkspaceId(userId);

  SimDevice get a => devices[0];

  SimDevice get b => devices[1];

  /// Push everyone, then pull everyone, twice — one pass would leave the first
  /// device having pulled before the last device pushed.
  Future<void> syncAll() async {
    for (var round = 0; round < 2; round++) {
      for (final device in devices) {
        await device.syncIfOnline();
      }
    }
  }

  Future<void> close() async {
    for (final device in devices) {
      await device.close();
    }
  }
}
