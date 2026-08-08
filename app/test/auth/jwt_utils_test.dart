/// `allowExpired` relaxes exactly one check, and nothing else.
///
/// It exists so an offline relaunch can recover the account id from a token it
/// already knows is stale rather than destroy the device's enrolment.
/// The risk worth pinning is scope creep: the flag must not start tolerating a
/// missing `sub` or an undecodable payload, because the id it yields is what
/// selects this device's local partitions.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/auth/jwt_utils.dart';

/// A JWT with the given payload claims and a signature segment that is never
/// checked — by design, and the reason `allowExpired` lowers no bar.
String _jwt(Map<String, Object?> claims) {
  final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
  final payload =
      base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');
  return '$header.$payload.sig';
}

int _secondsFromNow(int offset) =>
    DateTime.now().millisecondsSinceEpoch ~/ 1000 + offset;

void main() {
  group('extractUserIdFromJwt', () {
    test('an unexpired token yields its sub either way', () {
      final token = _jwt({'sub': 'user-1', 'exp': _secondsFromNow(3600)});
      expect(extractUserIdFromJwt(token), 'user-1');
      expect(extractUserIdFromJwt(token, allowExpired: true), 'user-1');
    });

    test('an expired token yields its sub only with allowExpired', () {
      final token = _jwt({'sub': 'user-2', 'exp': _secondsFromNow(-1)});
      expect(extractUserIdFromJwt(token), isNull);
      expect(extractUserIdFromJwt(token, allowExpired: true), 'user-2');
    });

    test('a token with no exp claim behaves the same way', () {
      final token = _jwt({'sub': 'user-3'});
      expect(extractUserIdFromJwt(token), isNull);
      expect(extractUserIdFromJwt(token, allowExpired: true), 'user-3');
    });

    test('an unparseable exp behaves the same way', () {
      final token = _jwt({'sub': 'user-4', 'exp': 'not-a-number'});
      expect(extractUserIdFromJwt(token), isNull);
      expect(extractUserIdFromJwt(token, allowExpired: true), 'user-4');
    });

    test('an exp given as a numeric string is still honoured', () {
      expect(
        extractUserIdFromJwt(
            _jwt({'sub': 'user-5', 'exp': '${_secondsFromNow(3600)}'})),
        'user-5',
      );
      expect(
        extractUserIdFromJwt(_jwt({'sub': 'user-5', 'exp': '${_secondsFromNow(-1)}'})),
        isNull,
      );
    });

    test('a missing sub is null with the flag as well as without', () {
      final token = _jwt({'exp': _secondsFromNow(-1)});
      expect(extractUserIdFromJwt(token), isNull);
      expect(extractUserIdFromJwt(token, allowExpired: true), isNull);
    });

    test('a non-string sub is null with the flag as well as without', () {
      final token = _jwt({'sub': 42, 'exp': _secondsFromNow(3600)});
      expect(extractUserIdFromJwt(token), isNull);
      expect(extractUserIdFromJwt(token, allowExpired: true), isNull);
    });

    test('the wrong number of segments is null with the flag as well as without',
        () {
      expect(extractUserIdFromJwt('only.two'), isNull);
      expect(extractUserIdFromJwt('only.two', allowExpired: true), isNull);
      expect(extractUserIdFromJwt('a.b.c.d', allowExpired: true), isNull);
    });

    test('an undecodable payload is null with the flag as well as without', () {
      expect(extractUserIdFromJwt('header.!!!not-base64!!!.sig'), isNull);
      expect(
        extractUserIdFromJwt('header.!!!not-base64!!!.sig', allowExpired: true),
        isNull,
      );
    });

    test('a payload that is valid base64 but not a JSON object is null', () {
      final notAnObject = base64Url.encode(utf8.encode('["a", "list"]'));
      expect(
        extractUserIdFromJwt('header.$notAnObject.sig', allowExpired: true),
        isNull,
      );
    });
  });
}
