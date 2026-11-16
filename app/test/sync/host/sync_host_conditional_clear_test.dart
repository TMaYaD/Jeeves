/// An abandoned activation undoes only its own member id: the clear is
/// conditional on the stored id still being the one it wrote.
@TestOn('!browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/host/hosted_capture.dart' show readClockIdentity;

import '../../test_helpers.dart';
import 'host_harness.dart';

const String _memberA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _memberB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  setUpAll(configureSqliteForTests);

  late HostDevice device;

  setUp(() async {
    device = HostDevice.open('A');
    await device.startHost();
    addTearDown(device.close);
  });

  Future<String?> storedMemberId() async =>
      (await readClockIdentity(device.domain)).enrolledMemberIdHex;

  test('a newer account\'s member id survives the older one\'s clear', () async {
    final host = device.host!;
    await host.setEnrolledMember(_memberA);
    await host.setEnrolledMember(_memberB);

    await host.clearEnrolledMemberIfEquals(_memberA);

    expect(await storedMemberId(), _memberB);
  });

  test('an activation clears the member id it wrote', () async {
    final host = device.host!;
    await host.setEnrolledMember(_memberA);

    await host.clearEnrolledMemberIfEquals(_memberA);

    expect(await storedMemberId(), isNull);
  });

  test('clearing when nothing is stored leaves nothing stored', () async {
    await device.host!.clearEnrolledMemberIfEquals(_memberA);

    expect(await storedMemberId(), isNull);
  });
}
