/// `user_preferences` on the op-log spine.
///
/// Same semantics as today's `UserPreferencesDao` — JSON-string values, delete
/// hides the key — reached by authoring ops instead of writing rows. This is a
/// parallel implementation, not a hook into the live DAO: the production app
/// stays on PowerSync until the cutover in #553, and teeing writes into both
/// would be exactly the dual-write branching the Implementation stance forbids.
///
/// Two differences from the DAO, both deliberate:
///
/// - The entity id is `uuid5(workspace_id, key)`, so two devices that create
///   the same preference while offline converge as one entity under field-grain
///   LWW instead of forking into two rows racing a unique constraint. This is a
///   KV-collection policy; #550's collections keep random client-generated ids.
/// - Deletion is a tombstone op, never row absence — which is what makes the
///   delete-on-absent reconciliation window structurally impossible.
library;

import 'collection_codecs.dart' show userPreferencesCollection;
import 'ids.dart';
import 'reducer.dart';
import 'sync_client.dart';

class PreferencesStore {
  PreferencesStore({required SyncClient client, required CollectionRegistry registry})
      : _client = client,
        _view = registry.register(userPreferencesCollection);

  final SyncClient _client;
  final CollectionView _view;

  /// The field holding the key itself. It never changes for a given entity —
  /// the id is derived from it — but it must be in the op for a device to be
  /// able to enumerate preferences it has only ever seen over the wire.
  static const String keyField = 'key';

  /// The one field that actually changes.
  static const String valueField = 'value';

  String entityIdFor(String key) =>
      preferenceEntityId(_client.workspaceId, key);

  Future<void> set(String key, String jsonValue) async {
    await _client.capture(
      collection: userPreferencesCollection,
      entityId: entityIdFor(key),
      fields: {keyField: key, valueField: jsonValue},
    );
  }

  Future<void> delete(String key) async {
    await _client.capture(
      collection: userPreferencesCollection,
      entityId: entityIdFor(key),
      tombstone: true,
    );
  }

  Future<String?> get(String key) async {
    final entity = await _view.readEntity(entityIdFor(key));
    return entity?[valueField] as String?;
  }

  Stream<String?> watch(String key) =>
      _view.watchEntity(entityIdFor(key)).map((entity) => entity?[valueField] as String?);

  Future<Map<String, String>> getAll() async => _asKeyValueMap(await _view.readAll());

  Stream<Map<String, String>> watchAll() => _view.watchAll().map(_asKeyValueMap);

  static Map<String, String> _asKeyValueMap(
    Map<String, Map<String, Object?>> entities,
  ) {
    final preferences = <String, String>{};
    for (final entity in entities.values) {
      final key = entity[keyField];
      final value = entity[valueField];
      if (key is String && value is String) preferences[key] = value;
    }
    return preferences;
  }
}
