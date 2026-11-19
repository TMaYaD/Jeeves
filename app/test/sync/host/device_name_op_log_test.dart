/// The device names itself over the op log.
///
/// Two phones, one account, one server: the name each device gives itself
/// once its sync activates, the names they can see of each other, and the
/// rule that a name is shown only for a device whose Grant this device has
/// applied.
///
/// The op log is the level that matters here. A name that never reaches the
/// log is a name the user's other device cannot show, and a name that reaches
/// the log under the wrong Workspace is a name a Service could read.
@TestOn('!browser')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/device_names.dart';
import 'package:jeeves/sync/envelope.dart' show opClassContent;
import 'package:jeeves/sync/ids.dart' show userPreferencesWorkspaceId;
import 'package:jeeves/sync/sync_lifecycle.dart';

import '../../test_helpers.dart';
import '../harness/fake_sync_server.dart';
import '../harness/sim_device.dart' show FakeClock;
import '../harness/sim_workspace.dart' show simulationStartWallMs;
import '../harness/stack_phone.dart';

const String _userId = 'names-user';
const String _plainUserId = 'names-plain-user';
const String _passphrase = 'correct horse battery staple';

/// An id no device holds: 32 hex characters that name nothing in the account.
const String _strangerHex = '0f0e0d0c0b0a09080706050403020100';

void main() {
  setUpAll(configureSqliteForTests);

  late FakeSyncServer server;
  late FakeClock clock;

  setUp(() {
    server = FakeSyncServer();
    clock = FakeClock(simulationStartWallMs);
  });

  Future<StackPhone> hostedPhone(String label, {String userId = _userId}) async {
    final built = await StackPhone.create(
      label: label,
      userId: userId,
      server: server,
      clock: clock,
      hosted: true,
    );
    addTearDown(built.close);
    return built;
  }

  /// The names of one phone: a fixed platform name, and the peers this phone
  /// has verified — the Grants it has applied in the preferences Workspace.
  DeviceNames namesOf(StackPhone phone, String platformName) => DeviceNames(
        db: phone.domain,
        readPlatformName: () async => platformName,
        isVerifiedDevice: (nodeIdHex) async =>
            deviceHasAppliedGrant(await phone.preferencesClient, nodeIdHex),
      );

  final preferencesWorkspace = userPreferencesWorkspaceId(_userId);

  int contentOpsIn(String workspaceId) => server.storedOps
      .where((op) =>
          op.header?.opClass == opClassContent && op.workspaceId == workspaceId)
      .length;

  test('the first device names itself, and the name reaches the log', () async {
    final phone = await hostedPhone('A');
    final names = namesOf(phone, 'Pixel 8');

    await phone.enrolAsFirstDevice();
    expect(
      await phone.activate(
        onActivationFinished: () => names.ensureOwnNames(_userId),
      ),
      SyncActivation.active,
    );

    await (await phone.preferencesClient).flushOutbox();

    expect(
      contentOpsIn(preferencesWorkspace),
      greaterThan(0),
      reason: 'the name was authored to the preferences Workspace',
    );
    expect(
      await phone.domain.userPreferencesDao.get(
        _userId,
        deviceNameKey(phone.stack.identity.memberIdHex),
      ),
      jsonEncode('Pixel 8'),
      reason: 'the name is stored under the member id a peer sees',
    );
  });

  test('an un-enrolled device names itself and authors nothing', () async {
    final phone = await hostedPhone('A');
    final names = namesOf(phone, 'Kitchen Tablet');

    expect(
      await phone.activate(
        onActivationFinished: () => names.ensureOwnNames(_userId),
      ),
      SyncActivation.notEnrolled,
    );

    expect(
      await phone.domain.userPreferencesDao.get(
        _userId,
        deviceNameKey(phone.host!.deviceNodeId),
      ),
      jsonEncode('Kitchen Tablet'),
      reason: 'the name exists before the device is enrolled',
    );
    expect(
      contentOpsIn(preferencesWorkspace),
      0,
      reason: 'an un-enrolled device authors no op',
    );
  });

  group('two devices in one account', () {
    late StackPhone a;
    late StackPhone b;
    late DeviceNames aNames;
    late DeviceNames bNames;

    setUp(() async {
      a = await hostedPhone('A');
      aNames = namesOf(a, "Asha's Pixel");
      await a.enrolAsFirstDevice(passphrase: _passphrase);
      expect(
        await a.activate(
          onActivationFinished: () => aNames.ensureOwnNames(_userId),
        ),
        SyncActivation.active,
      );
      await (await a.preferencesClient).flushOutbox();

      b = await hostedPhone('B');
      bNames = namesOf(b, 'Kitchen Tablet');
      await b.enrolWithPassphrase(_passphrase);
      expect(
        await b.activate(
          onActivationFinished: () => bNames.ensureOwnNames(_userId),
        ),
        SyncActivation.active,
      );
      await (await b.preferencesClient).flushOutbox();
    });

    test('each device shows the other\'s name', () async {
      expect(
        await bNames.nameOf(_userId, a.stack.identity.memberIdHex),
        "Asha's Pixel",
        reason: 'the peer\'s name arrived over the log',
      );

      await (await a.preferencesClient).sync();
      expect(
        await aNames.nameOf(_userId, b.stack.identity.memberIdHex),
        'Kitchen Tablet',
        reason: 'and the other way round, once A has pulled',
      );
    });

    test('a rename reaches the other device', () async {
      clock.advance(1000);
      await aNames.renameThisDevice(_userId, "Asha's new phone");
      await (await a.preferencesClient).flushOutbox();

      await (await b.preferencesClient).sync();
      expect(
        await bNames.nameOf(_userId, a.stack.identity.memberIdHex),
        "Asha's new phone",
      );
    });

    test('a name for an id with no Grant is not shown', () async {
      await b.domain.userPreferencesDao.set(
        _userId,
        deviceNameKey(_strangerHex),
        jsonEncode('Nobody'),
      );

      expect(
        await bNames.nameOf(_userId, _strangerHex),
        isNull,
        reason: 'a name is shown only for a device this one has verified',
      );
    });
  });

  test('a name set before sign-in carries into the account', () async {
    final a = await hostedPhone('A');
    final aNames = namesOf(a, "Asha's Pixel");
    await aNames.renameThisDevice('local', 'Signed out name');

    await a.enrolAsFirstDevice(passphrase: _passphrase);
    expect(
      await a.activate(
        onActivationFinished: () => aNames.ensureOwnNames(_userId),
      ),
      SyncActivation.active,
    );

    expect(
      await a.domain.userPreferencesDao.get(
        _userId,
        deviceNameKey(a.stack.identity.memberIdHex),
      ),
      jsonEncode('Signed out name'),
      reason: 'the name set while signed out is the account\'s name',
    );

    await (await a.preferencesClient).flushOutbox();

    final b = await hostedPhone('B');
    final bNames = namesOf(b, 'Kitchen Tablet');
    await b.enrolWithPassphrase(_passphrase);
    expect(
      await b.activate(
        onActivationFinished: () => bNames.ensureOwnNames(_userId),
      ),
      SyncActivation.active,
    );
    await (await b.preferencesClient).flushOutbox();

    expect(
      await bNames.nameOf(_userId, a.stack.identity.memberIdHex),
      'Signed out name',
      reason: 'and the other device shows the same name',
    );
  });

  test('the hook does not change what an activation returns', () async {
    final hooked = await hostedPhone('A');
    final plain = await hostedPhone('B', userId: _plainUserId);

    expect(
      await hooked.activate(
        onActivationFinished: () =>
            namesOf(hooked, 'Pixel 8').ensureOwnNames(_userId),
      ),
      SyncActivation.notEnrolled,
    );
    expect(await plain.activate(), SyncActivation.notEnrolled);

    await hooked.enrolAsFirstDevice();
    await plain.enrolAsFirstDevice();
    expect(
      await hooked.activate(
        onActivationFinished: () =>
            namesOf(hooked, 'Pixel 8').ensureOwnNames(_userId),
      ),
      SyncActivation.active,
    );
    expect(await plain.activate(), SyncActivation.active);
  });

  test('after-activation work that fails does not fail the activation',
      () async {
    final phone = await hostedPhone('A');
    await phone.enrolAsFirstDevice();

    expect(
      await phone.activate(
        onActivationFinished: () async => throw StateError('no name today'),
      ),
      SyncActivation.active,
      reason: 'the activation result is the caller\'s answer and does not move',
    );
  });
}
