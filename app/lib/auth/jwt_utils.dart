import 'dart:convert';

/// Decode a JWT and return the `sub` claim if the token is not expired.
///
/// Returns null for malformed tokens, missing `sub`, or expired tokens.
String? extractUserIdFromJwt(String token) {
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
    final exp = json['exp'];
    final expSeconds =
        exp is int ? exp : (exp is String ? int.tryParse(exp) : null);
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (expSeconds == null) return null;
    if (expSeconds <= nowSeconds) return null;
    return json['sub'] as String?;
  } catch (_) {
    return null;
  }
}
