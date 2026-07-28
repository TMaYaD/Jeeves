/// The escrow blob: wrap, unwrap, and the KDF floor that guards both.
///
/// These run the real Argon2id and the real XChaCha20-Poly1305, at reduced cost
/// parameters injected as *both* the parameters and the floor — so the floor
/// check runs on every case here exactly as it does in production, and only the
/// cost is smaller.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/recovery_escrow.dart';
import 'package:jeeves/sync/root_authority.dart';

const Argon2idParameters _testKdf = Argon2idParameters(
  memoryKib: 32,
  timeCost: 1,
  parallelism: 1,
);

const String _passphrase = 'correct horse battery staple twelve monkeys';

Uint8List _bytes(int fill) => Uint8List.fromList(List<int>.filled(32, fill));

Matcher throwsEscrow(RecoveryEscrowFailure failure) => throwsA(
      predicate<Object>(
        (error) => error is RecoveryEscrowException && error.failure == failure,
        'a RecoveryEscrowException (${failure.code})',
      ),
    );

void main() {
  final secrets = EscrowedSecrets(
    rootSecretKey: _bytes(0x11),
    masterWrapKey: _bytes(0x22),
  );

  Future<Uint8List> wrap({
    String passphrase = _passphrase,
    Argon2idParameters parameters = _testKdf,
    Argon2idParameters floor = _testKdf,
  }) =>
      wrapEscrowBlob(
        passphrase: passphrase,
        secrets: secrets,
        parameters: parameters,
        floor: floor,
      );

  group('blob v1', () {
    test('round-trips both secrets', () async {
      final blob = await wrap();
      expect(blob.length, escrowBlobBytes);
      expect(blob.sublist(0, 4), escrowBlobMagic);

      final recovered = await unwrapEscrowBlob(
        blob: blob,
        passphrase: _passphrase,
        floor: _testKdf,
      );
      expect(recovered.rootSecretKey, secrets.rootSecretKey);
      // Escrowed now, read by nothing until #554 — but it has to survive the
      // round trip, or a passphrase change would silently lose it.
      expect(recovered.masterWrapKey, secrets.masterWrapKey);
    });

    test('carries its KDF parameters in the clear', () async {
      final parameters = readEscrowBlobParameters(await wrap(), floor: _testKdf);
      expect(parameters.memoryKib, _testKdf.memoryKib);
      expect(parameters.timeCost, _testKdf.timeCost);
      expect(parameters.parallelism, _testKdf.parallelism);
    });

    test('two wraps of the same secrets differ', () async {
      // Fresh salt and nonce each time: identical blobs would leak that the
      // passphrase did not change.
      expect(await wrap(), isNot(await wrap()));
    });

    test('a wrong passphrase is a prompt, not an alarm', () async {
      final blob = await wrap();
      try {
        await unwrapEscrowBlob(
          blob: blob,
          passphrase: 'not the passphrase',
          floor: _testKdf,
        );
        fail('expected the AEAD to refuse');
      } on RecoveryEscrowException catch (error) {
        expect(error.failure, RecoveryEscrowFailure.wrongPassphrase);
        // The one failure in this vocabulary that is a user mistake.
        expect(error.isAlarm, isFalse);
      }
    });

    test('a tampered header fails the AEAD, because it is the AAD', () async {
      final blob = await wrap();
      // Flip a salt byte: the ciphertext is untouched, but the header is
      // authenticated as additional data, so the tag no longer matches.
      blob[14] ^= 0x01;
      expect(
        () => unwrapEscrowBlob(blob: blob, passphrase: _passphrase, floor: _testKdf),
        throwsEscrow(RecoveryEscrowFailure.wrongPassphrase),
      );
    });

    test('a blob of the wrong length or magic is malformed', () async {
      expect(
        () => readEscrowBlobParameters(Uint8List(10), floor: _testKdf),
        throwsEscrow(RecoveryEscrowFailure.malformedBlob),
      );
      final blob = await wrap();
      blob[0] = 0x00;
      expect(
        () => readEscrowBlobParameters(blob, floor: _testKdf),
        throwsEscrow(RecoveryEscrowFailure.malformedBlob),
      );
    });
  });

  group('KDF floor', () {
    test('refuses to write below the floor', () {
      // F12's weakened-params-at-write attack, closed at the writing end.
      expect(
        () => wrap(
          parameters: const Argon2idParameters(
            memoryKib: 8,
            timeCost: 1,
            parallelism: 1,
          ),
        ),
        throwsEscrow(RecoveryEscrowFailure.kdfBelowFloor),
      );
    });

    test('refuses to read below the floor, before any KDF work', () async {
      // Written under weak parameters by something that did not check, and
      // refused here on the way in. The refusal comes from
      // `readEscrowBlobParameters`, which does no key derivation at all.
      final weak = const Argon2idParameters(
        memoryKib: 8,
        timeCost: 1,
        parallelism: 1,
      );
      final blob = await wrap(parameters: weak, floor: weak);

      expect(
        () => readEscrowBlobParameters(blob, floor: _testKdf),
        throwsEscrow(RecoveryEscrowFailure.kdfBelowFloor),
      );
      expect(
        () => unwrapEscrowBlob(blob: blob, passphrase: _passphrase, floor: _testKdf),
        throwsEscrow(RecoveryEscrowFailure.kdfBelowFloor),
      );
    });

    test('accepts parameters at or above the floor', () async {
      final stronger = Argon2idParameters(
        memoryKib: _testKdf.memoryKib * 2,
        timeCost: _testKdf.timeCost + 1,
        parallelism: _testKdf.parallelism,
      );
      expect(stronger.meetsFloor(_testKdf), isTrue);
      expect(_testKdf.meetsFloor(_testKdf), isTrue);
      final blob = await wrap(parameters: stronger);
      expect(
        (await unwrapEscrowBlob(
          blob: blob,
          passphrase: _passphrase,
          floor: _testKdf,
        ))
            .rootSecretKey,
        secrets.rootSecretKey,
      );
    });

    test('the production floor is the one the protocol pins', () {
      expect(Argon2idParameters.floor.memoryKib, argon2idFloorMemoryKib);
      expect(Argon2idParameters.floor.timeCost, argon2idFloorTimeCost);
      expect(Argon2idParameters.floor.parallelism, argon2idFloorParallelism);
    });
  });

  group('record signature', () {
    final workspaceId = defaultWorkspaceId('escrow-test-user');

    test('binds the workspace and the version', () async {
      final root = await RootAuthority.fromSecretKey(_bytes(0x33));
      final blob = await wrap();
      final record = await root.escrowRecord(
        workspaceId: workspaceId,
        version: firstEscrowVersion,
        blob: blob,
      );

      await verifyEscrowRecordSignature(record, workspaceId, root.rootPk);

      // Same bytes, another slot: refused, and as an alarm rather than a prompt.
      expect(
        () => verifyEscrowRecordSignature(
          record,
          defaultWorkspaceId('somebody-else'),
          root.rootPk,
        ),
        throwsEscrow(RecoveryEscrowFailure.rootMismatch),
      );
      // Same bytes, another version.
      expect(
        () => verifyEscrowRecordSignature(
          RecoveryEscrowRecord(
            version: 2,
            blob: record.blob,
            rootSig: record.rootSig,
            rootPk: record.rootPk,
          ),
          workspaceId,
          root.rootPk,
        ),
        throwsEscrow(RecoveryEscrowFailure.rootMismatch),
      );
    });

    test('a record from another Root is an alarm', () async {
      final root = await RootAuthority.fromSecretKey(_bytes(0x44));
      final impostor = await RootAuthority.fromSecretKey(_bytes(0x55));
      final record = await impostor.escrowRecord(
        workspaceId: workspaceId,
        version: firstEscrowVersion,
        blob: await wrap(),
      );
      expect(
        () => verifyEscrowRecordSignature(record, workspaceId, root.rootPk),
        throwsEscrow(RecoveryEscrowFailure.rootMismatch),
      );
    });
  });

  group('Root', () {
    test('is reopenable from its secret and refuses use after being dropped',
        () async {
      final root = await RootAuthority.fromSecretKey(_bytes(0x66));
      final reopened = await RootAuthority.fromSecretKey(_bytes(0x66));
      expect(reopened.rootPk, root.rootPk);

      root.drop();
      // Best-effort zeroize, but a use-after-drop is loud rather than a quiet
      // signature with a key that should be gone.
      expect(() => root.secretKey, throwsStateError);
    });
  });
}
