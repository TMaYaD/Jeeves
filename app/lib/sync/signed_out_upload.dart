/// Authors what the device wrote while nobody was signed in, once an account that
/// already uploaded is back.
///
/// A write made signed out is clocked under the device node id and no op ever
/// carries it. The enrolment upload covers an account's first sign-in; for every
/// later one this pass does the same job. Like the enrolment upload it decides by
/// reading state rather than remembering a run: `SyncClient.capture` re-stamps what
/// it authors under the member id, so a second pass finds nothing device-stamped.
///
/// Source and filters are `SyncHostService.visibleChangesStampedByDeviceAfter`.
/// The account's upload completion time is the cut-off: older device-stamped state
/// is what that upload deliberately left off the log.
///
/// A preference is the account's own only when its key derives to the entity id
/// the account's preferences Workspace holds. A setting carried into the account
/// at sign-in is the account's own and reaches the account's other devices; a row
/// stored under the signed-out `'local'` id names an entity that Workspace does
/// not hold, and stays off the log.
library;

import 'dart:developer' as developer;

import 'collection_codecs.dart' show userPreferencesCollection;
import 'envelope.dart' show SyncRejection;
import 'hlc.dart';
import 'host/change.dart';
import 'ids.dart' show preferenceEntityId;
import 'sync_client.dart';

/// What one pass did.
class SignedOutUploadReport {
  const SignedOutUploadReport({
    required this.authoredOpCount,
    required this.refusedEntityCount,
  });

  final int authoredOpCount;
  final int refusedEntityCount;
}

/// Author [readChanges]'s result through [gtdClient], and the preferences among
/// them through [preferencesClient].
///
/// Both clocks are minted **before** the read: a write the user makes during the
/// pass is stamped later than they are and so wins over the older value read. The
/// field clock is minted after the tombstone clock, so a delete-then-re-add made
/// signed out ends visible.
Future<SignedOutUploadReport> runSignedOutUpload({
  required Future<List<Change>> Function() readChanges,
  required Hlc Function() mintClock,
  required SyncClient gtdClient,
  required SyncClient preferencesClient,
  required String userId,
}) async {
  final tombstoneClock = mintClock();
  final fieldClock = mintClock();
  var authored = 0;
  var refused = 0;
  for (final change in await readChanges()) {
    final isPreference = change.collection == userPreferencesCollection;
    // A preference the account does not hold is skipped, not refused: there is
    // nothing to author it into, and a refusal would say the account's own
    // Workspace refused a row it never wanted.
    if (isPreference && !_isOwnedByThisAccount(change, preferencesClient)) {
      continue;
    }
    final client = isPreference ? preferencesClient : gtdClient;
    try {
      if (change.tombstone != null) {
        await client.capture(
          collection: change.collection,
          entityId: change.entityId,
          tombstone: true,
          clock: tombstoneClock,
        );
        authored++;
      }
      if (change.fields.isNotEmpty) {
        await client.capture(
          collection: change.collection,
          entityId: change.entityId,
          fields: {
            for (final field in change.fields.entries)
              // Rows created signed out carry the placeholder owner; the account
              // owns them on the log, as the enrolment upload stamps them.
              field.key:
                  field.key == 'user_id' ? userId : field.value.value,
          },
          clock: fieldClock,
        );
        authored++;
      }
    } on SyncRejection catch (rejection) {
      refused++;
      developer.log(
        'signed-out change refused; left device-stamped for the next activation',
        name: 'jeeves.sync.signed_out_upload',
        level: 900, // WARNING
        error: '${change.collection}/${change.entityId}: '
            '${rejection.reason.code}: ${rejection.message}',
      );
    }
  }
  return SignedOutUploadReport(
    authoredOpCount: authored,
    refusedEntityCount: refused,
  );
}

/// Whether [change] is a preference this account holds: its key derives to its
/// entity id in [preferencesClient]'s preferences Workspace.
///
/// The derivation is the rule, not a list of user ids: a row stored under the
/// signed-out `'local'` id — or under a previous account's — derives to another
/// Workspace's entity, so it names an entity this account's log does not hold.
/// A change that carries no key cannot be checked against the derivation at all,
/// so it is not the account's either.
bool _isOwnedByThisAccount(Change change, SyncClient preferencesClient) {
  final key = change.fields['key']?.value;
  if (key is! String) return false;
  return preferenceEntityId(preferencesClient.workspaceId, key) ==
      change.entityId;
}
