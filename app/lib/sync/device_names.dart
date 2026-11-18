/// The name a user gives to the device they are holding.
///
/// A Device has two ids a peer can see on a change: the device node id it is
/// born with, and — once it is enrolled — the member id it is given. A name
/// is stored under **both**, as ordinary synced data in the `user_preferences`
/// store, so a peer can turn "the id that authored this change" into a name
/// without the app ever having to invent a device registry.
///
/// **The key is `device_name.<node id hex>`.** One key per id, so names merge
/// like every other preference (last write wins) and a rename is one write per
/// id rather than a write to a row a peer would have to look up. The key
/// family is deliberately *not* in the conflict registry: the default is
/// already `lww`, and a client-only rule would have nothing to mirror on the
/// server side. A test pins the strategy instead.
///
/// Nothing here is a ceremony step and nothing waits on the user: a device
/// that has never been named is simply unnamed until the user names it, and a
/// failure to name it is a log line, never a crash.
///
/// **Reading a name is a separate question from writing one.** A peer that
/// sees an id on a change may turn it into that device's name, or into nothing
/// — never into the raw id. See [DeviceNames.nameOf].
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart' show debugPrint;

import '../database/gtd_database.dart';
import 'hlc.dart';
import 'host/hosted_capture.dart';
import 'sync_client.dart';

/// The preference key holding the name of the device with [nodeId].
///
/// [nodeId] is a device node id or a member id, in either the dashed UUID form
/// or the 32-hex form a clock carries. Both spellings name the same id, so
/// both produce the same key: a peer must not end up with two rows for one
/// device because two callers disagreed on spelling.
///
/// Throws [ArgumentError] for anything else, because a malformed id would
/// silently produce a key no peer would ever ask for.
String deviceNameKey(String nodeId) {
  final hex = memberIdToHex(nodeId);
  if (!memberIdHexPattern.hasMatch(hex)) {
    throw ArgumentError.value(
      nodeId,
      'nodeId',
      'must be a UUID or 32 lowercase hex characters',
    );
  }
  return 'device_name.$hex';
}

/// The longest a device name may be, in Unicode code points.
const int maxDeviceNameLength = 40;

/// Control characters and whitespace, in runs: they become one space.
final RegExp _deviceNameWhitespace = RegExp(r'[\x00-\x1F\x7F\s]+');

/// Normalises [raw] into a device name, or `null` when there is no name.
///
/// A stored value is untrusted input — it may have been written by another
/// device — so this runs on read as well as on write: control characters and
/// runs of whitespace collapse to one space, the result is trimmed, and it is
/// cut to [maxDeviceNameLength] code points.
///
/// The cut is by **code point**, not by UTF-16 code unit: cutting in the
/// middle of a surrogate pair would leave half a character in the name, which
/// no peer could render.
///
/// Anything that is not a string, and any string that is empty once
/// normalised, is `null`. "No name" is the whole answer, and every caller
/// phrases it in its own words.
String? normaliseDeviceName(Object? raw) {
  if (raw is! String) return null;
  final collapsed = raw.replaceAll(_deviceNameWhitespace, ' ').trim();
  if (collapsed.isEmpty) return null;
  final runes = collapsed.runes;
  if (runes.length <= maxDeviceNameLength) return collapsed;
  return String.fromCharCodes(runes.take(maxDeviceNameLength));
}

/// Reads and writes the names this device gives itself, and resolves the names
/// of the peers it can see.
class DeviceNames {
  DeviceNames({
    required GtdDatabase db,
    required Future<String?> Function() readPlatformName,
    Future<bool> Function(String nodeIdHex)? isVerifiedDevice,
  })  : _db = db,
        _readPlatformName = readPlatformName,
        _isVerifiedDevice = isVerifiedDevice;

  final GtdDatabase _db;

  /// The platform's own name for this device ("Pixel 8"), or `null` when the
  /// platform has none to give or the read failed.
  final Future<String?> Function() _readPlatformName;

  /// Whether a peer id is a Device this device has verified.
  ///
  /// Absent means no peer is verified: a device that has not been told how to
  /// check shows names for its own ids only.
  final Future<bool> Function(String nodeIdHex)? _isVerifiedDevice;

  /// This device's own ids: the device node id it was born with, and the
  /// member id it was given when it enrolled.
  ///
  /// Both, because both can appear on a change a peer sees: a write made
  /// before enrolment is clocked with the device node id, a write made after
  /// it is clocked with the member id. A name stored under only one of them
  /// would leave the other unreadable.
  Future<List<String>> ownNodeIds() async {
    final identity = await readClockIdentity(_db);
    final ids = <String>[identity.deviceNodeId];
    final enrolled = identity.enrolledMemberIdHex;
    if (enrolled != null && enrolled.isNotEmpty) ids.add(enrolled);
    return ids;
  }

  /// Makes sure every own id carries a name for [userId].
  ///
  /// Idempotent, and never throws to its caller: a device that cannot be
  /// named is a device without a name, which is a state the app already
  /// handles. Writes nothing when every own id already has a live value.
  Future<void> ensureOwnNames(String userId) async {
    try {
      final ids = await ownNodeIds();
      if (ids.isEmpty) return;
      final keys = [for (final id in ids) deviceNameKey(id)];
      final stored = await _db.userPreferencesDao.getAll(userId);

      final missing = <String>[];
      for (final key in keys) {
        if (_decodeName(stored[key]) == null) missing.add(key);
      }
      if (missing.isEmpty) return;

      final seed = await _seedName(keys, stored);
      if (seed == null) return;

      await _db.userPreferencesDao.setAll(userId, {
        for (final key in missing) key: jsonEncode(seed),
      });
    } on Object catch (error) {
      debugPrint('device names: ensure failed — $error');
    }
  }

  /// The name a missing id should take, or `null` when there is none to give.
  ///
  /// In order: a name this user already gave another of this device's ids;
  /// the newest name this device carries under any of its ids for **any**
  /// user (so a name set while signed out carries into the account); and
  /// last the platform's own name.
  ///
  /// The platform is the last resort and is asked for only when nothing else
  /// is known, so a device that already has a name never asks the OS again.
  Future<String?> _seedName(
    List<String> keys,
    Map<String, String> storedForUser,
  ) async {
    for (final key in keys) {
      final name = _decodeName(storedForUser[key]);
      if (name != null) return name;
    }
    final carried = await _newestNameForAnyUser(keys);
    if (carried != null) return carried;
    return normaliseDeviceName(await _readPlatformName());
  }

  /// The newest live name stored under any of [keys], whoever the user is.
  ///
  /// The rows are compared in Dart rather than by the SQL `updated_at` order,
  /// because that column is an ISO-8601 string whose fractional part is not
  /// fixed-width: `ORDER BY` would compare "…:06.123Z" against "…:06.123456Z"
  /// and pick the wrong one.
  Future<String?> _newestNameForAnyUser(List<String> keys) async {
    final placeholders = List.filled(keys.length, '?').join(', ');
    final rows = await _db.customSelect(
      'SELECT value, updated_at FROM user_preferences WHERE "key" IN '
      '($placeholders) AND value IS NOT NULL',
      variables: [for (final key in keys) Variable(key)],
    ).get();
    DateTime? newestAt;
    String? newest;
    for (final row in rows) {
      final updatedAt = DateTime.tryParse(row.read<String>('updated_at'));
      if (updatedAt == null) continue;
      if (newestAt != null && !updatedAt.isAfter(newestAt)) continue;
      final name = _decodeName(row.read<String?>('value'));
      if (name == null) continue;
      newestAt = updatedAt;
      newest = name;
    }
    return newest;
  }

  /// Names this device, under every id it has.
  ///
  /// [name] is normalised first, so what is stored is what a peer will read.
  /// Throws [ArgumentError] when the name is empty once normalised — there is
  /// no such thing as an unnamed name, and a silent no-op would leave the user
  /// thinking they had renamed the device.
  Future<void> renameThisDevice(String userId, String name) async {
    final normalised = normaliseDeviceName(name);
    if (normalised == null) {
      throw ArgumentError.value(
        name,
        'name',
        'must be a name with at least one visible character',
      );
    }
    final ids = await ownNodeIds();
    if (ids.isEmpty) return;
    await _db.userPreferencesDao.setAll(userId, {
      for (final id in ids) deviceNameKey(id): jsonEncode(normalised),
    });
  }

  /// This device's name, as it changes.
  ///
  /// Reads the value under the device node id — the id every device has from
  /// the moment it is born, enrolled or not.
  Stream<String?> watchThisDeviceName(String userId) async* {
    final ids = await ownNodeIds();
    if (ids.isEmpty) {
      yield null;
      return;
    }
    final key = deviceNameKey(ids.first);
    yield* _db.userPreferencesDao.watch(userId, key).map(_decodeName);
  }

  /// The name in a stored preference value, or `null`.
  ///
  /// The value is JSON — the store holds JSON strings — but it arrives from
  /// whatever another device wrote, so it may be absent, malformed, or not a
  /// string at all. Each of those is "no name", never an exception on a read
  /// the caller could have recovered from.
  static String? _decodeName(String? raw) {
    if (raw == null) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    return normaliseDeviceName(decoded);
  }

  /// The name of the device with [nodeId], or `null` when there is no name to
  /// show.
  ///
  /// A name is shown for **this device's own ids**, and for a peer whose
  /// identity the chain rules have verified — a peer with an applied Grant in
  /// the preferences Workspace. Anything else, and any stored value that is
  /// absent, tombstoned or not a name, is `null`: the caller phrases the
  /// `null` case in its own words.
  ///
  /// **The resolver never returns an id.** A name that is exactly the id it
  /// was asked about is refused, so no caller can put a raw id on screen by
  /// accident.
  Future<String?> nameOf(String userId, String nodeId) async {
    final hex = memberIdToHex(nodeId);
    if (!memberIdHexPattern.hasMatch(hex)) return null;

    if (!await _isOwnId(hex) && !await _isVerified(hex)) return null;

    final stored = await _db.userPreferencesDao.get(userId, deviceNameKey(hex));
    final name = _decodeName(stored);
    if (name == null) return null;
    if (name == hex) return null;
    return name;
  }

  /// Whether [hex] is one of this device's own ids.
  Future<bool> _isOwnId(String hex) async {
    for (final id in await ownNodeIds()) {
      if (memberIdToHex(id) == hex) return true;
    }
    return false;
  }

  /// Whether the peer with id [hex] is a verified Device.
  ///
  /// A verification that fails is a peer that is not verified: the answer to
  /// "may I show this device's name?" is never "yes" because a check broke.
  Future<bool> _isVerified(String hex) async {
    final predicate = _isVerifiedDevice;
    if (predicate == null) return false;
    try {
      return await predicate(hex);
    } on Object catch (error) {
      debugPrint('device names: verification failed — $error');
      return false;
    }
  }
}

/// Whether the device with id [nodeIdHex] holds a Grant in the control log
/// [preferencesClient] has applied.
///
/// The applied control log holds only Grants that passed the chain rules, and
/// in the preferences Workspace only Devices can be granted — so a Grant here
/// is the evidence that an id belongs to a Device this device trusts.
///
/// A **revoked** Grant counts too: a device that was trusted keeps its name
/// for the changes it made while it was trusted.
Future<bool> deviceHasAppliedGrant(
  SyncClient preferencesClient,
  String nodeIdHex,
) async {
  final view = await preferencesClient.grantsView();
  for (final grant in view.grants.values) {
    if (memberIdToHex(grant.memberId) == nodeIdHex) return true;
  }
  return false;
}
