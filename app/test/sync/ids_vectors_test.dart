/// The derived ids, pinned.
///
/// A derivation is protocol identity, not implementation detail: two devices
/// that derive different ids for the same thing never converge, and the
/// difference is invisible until it is too late. These literals are the vectors.
/// A derivation that moves is a protocol change, and it fails here first.
///
/// The values are `uuid5(NAMESPACE_URL, name)`; the names are the derivation of
/// record, one per function in `lib/sync/ids.dart`.
@TestOn('!browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/ids.dart';

const String _outcomeId = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';
const String _tagId = '9f8e7d6c-5b4a-4938-8271-605f4e3d2c1b';

void main() {
  test('the workspace ids are pinned', () {
    expect(defaultWorkspaceId('user-1'), 'd1d3a761-1c94-5101-a33a-f8bc7e4c39b0');
    expect(userPreferencesWorkspaceId('user-1'),
        'e2c92fa7-5dbd-5fbc-9f74-8aa62a19e84a');
    expect(preferenceEntityId(defaultWorkspaceId('user-1'), 'theme'),
        '4459780a-5608-5114-aa5f-27a395e0e51d');
  });

  test('the junction ids are pinned', () {
    expect(todoTagIdFor(_outcomeId, _tagId),
        '6a491c1c-35be-5f7e-830d-039671bbb803');
    expect(captureTagIdFor('capture-1', _tagId),
        'bce64b21-6b6e-5744-9d1c-131b49fd28f7');
    expect(focusSessionTaskIdFor('session-1', 'task-1'),
        '4153270b-5e11-5dbf-8219-7c74c43de966');
  });

  test('the ids a hand edit derives are pinned', () {
    // Two devices that read the same hand edit create one Action: the id says
    // what was typed, not who typed it.
    expect(vaultHandEditedActionIdFor(_outcomeId, 'call Sam', 0),
        '83fd30b3-6d23-5281-a5fd-4d151741c45f');
    // A second line with the same text is a second Action.
    expect(vaultHandEditedActionIdFor(_outcomeId, 'call Sam', 1),
        'ebd814d4-9268-5cfc-9b2a-c538725eedce');
    // A Tag a person typed is named after what was typed.
    expect(vaultHandEditedTagIdFor('Home', 'label'),
        'f6fb429c-ffb2-5b21-a068-d662b1c0959b');
  });
}
