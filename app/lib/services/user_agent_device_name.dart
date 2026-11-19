/// The name a browser can be reduced to.
///
/// A browser has no device name to ask for. The only thing it will tell us is
/// who it is pretending to be, which is enough for a name a person can
/// recognise — "Chrome on macOS" — and not enough for one that means anything
/// on its own. That is why it is a *default* and not a label: the user can
/// replace it, and a device nobody renames is still recognisable.
///
/// Pure: a string in, a string out. The platform adapter owns the read; this
/// file owns the meaning.
library;

/// The browser tokens, in the order they are looked for.
///
/// Order is the whole point. Edge and Opera both carry a `Chrome/` token, so
/// they have to be found first or they would be reported as Chrome — and the
/// name is what a person reads, so a wrong browser is a wrong name.
const List<(String, String)> _browserTokens = <(String, String)>[
  ('Edg/', 'Edge'),
  ('OPR/', 'Opera'),
  ('Firefox/', 'Firefox'),
  ('Chrome/', 'Chrome'),
  ('Safari/', 'Safari'),
];

/// The operating-system tokens, in the order they are looked for.
///
/// Order is the whole point here too. An Android user agent says `Linux`
/// before it says `Android`, and an iPhone user agent says `Mac OS X` before
/// it says `iPhone`; both would be wrong, so both specific tokens come first.
const List<(String, String)> _osTokens = <(String, String)>[
  ('Android', 'Android'),
  ('iPhone', 'iOS'),
  ('iPad', 'iOS'),
  ('Windows', 'Windows'),
  ('Mac OS X', 'macOS'),
  ('CrOS', 'ChromeOS'),
  ('Linux', 'Linux'),
];

/// Reads the browser and the operating system out of a user agent string.
///
/// Returns `<Browser> on <OS>`, or whichever of the two was found, or `null`
/// when the string says nothing we recognise.
String? deviceNameFromUserAgent(String userAgent) {
  final String? browser = _firstMatch(userAgent, _browserTokens);
  final String? os = _firstMatch(userAgent, _osTokens);
  if (browser != null && os != null) {
    return '$browser on $os';
  }
  return browser ?? os;
}

/// The label of the first token the user agent contains.
String? _firstMatch(String userAgent, List<(String, String)> tokens) {
  for (final (String token, String label) in tokens) {
    if (userAgent.contains(token)) {
      return label;
    }
  }
  return null;
}
