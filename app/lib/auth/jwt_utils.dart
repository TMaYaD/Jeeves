import 'dart:convert';

/// Decode a JWT and return the `sub` claim.
///
/// Returns null for malformed tokens, a missing `sub`, and — unless
/// [allowExpired] — a token whose `exp` is in the past or absent.
///
/// [allowExpired] is for the one caller that needs the account id out of a token
/// it already knows is stale: an offline relaunch whose silent refresh was
/// inconclusive, which keeps the device signed in rather than destroying its
/// enrolment (ADR-0041, `session_restore.dart`). It relaxes **only** the `exp`
/// check — an undecodable payload or a missing `sub` still yields null.
///
/// It lowers no security bar. Nothing here verifies the token's signature, with
/// or without the flag, so there was no bar to lower; and the id it yields
/// carries no authority — it selects local partitions (the `uuid5` Workspace ids,
/// the escrow slot) and nothing else. Every real authority rests on the
/// server-checked bearer or member credential.
String? extractUserIdFromJwt(String token, {bool allowExpired = false}) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = parts[1];
    final padded = payload.padRight(
      payload.length + (4 - payload.length % 4) % 4,
      '=',
    );
    final decoded = utf8.decode(base64Url.decode(padded));
    final json = jsonDecode(decoded) as Map<String, dynamic>;
    if (!allowExpired) {
      final exp = json['exp'];
      final expSeconds =
          exp is int ? exp : (exp is String ? int.tryParse(exp) : null);
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (expSeconds == null) return null;
      if (expSeconds <= nowSeconds) return null;
    }
    return json['sub'] as String?;
  } catch (_) {
    return null;
  }
}
