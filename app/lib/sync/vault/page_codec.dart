/// The text of one vault page, to and from a page model.
///
/// Pure text: no files, no host, no merge. A page is
///
/// ```
/// ---
/// id: ...
/// title: ...
/// ---
/// <notes, byte for byte>
/// ## Actions
/// - [ ] a line
///
/// <!-- jeeves-sync 1
/// Written by Jeeves. Leave this block alone.
/// <base64 of the block, wrapped>
/// -->
/// ```
///
/// The block is the page's machine data: for each field of each entity on the
/// page, the clock of its last change and a digest of the value it stamped. A
/// value that matches its digest is what some device wrote at that clock; one
/// that does not was edited by hand. The encoding is base64 so no value can ever
/// close the comment (it holds no `--`).
///
/// A checklist line holds one line of text: a line end in it is written `\n` or
/// `\r`, so the text survives the page whole.
////// A page is a pure function of its model: fixed field order, sorted entries,
/// `\n` line ends, nothing read from the device. Two devices in the same state
/// write the same bytes.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../hlc.dart';

const int pageBlockVersion = 1;

const String _blockOpen = '<!-- jeeves-sync ';
const String _blockNotice = 'Written by Jeeves. Leave this block alone.';
const String _actionsHeading = '## Actions';

/// One field of one entity on a page: the clock of its last change, a digest of
/// the value that clock stamped, and — for a field the page does not show — the
/// value itself. A deletion is an entry whose [field] is [tombstoneField].
class BlockEntry {
  const BlockEntry({
    required this.collection,
    required this.entityId,
    required this.field,
    required this.hlc,
    required this.digest,
    this.hasCarriedValue = false,
    this.carriedValue,
  });

  /// The `field` of an entry that records the entity's deletion.
  static const String tombstoneField = '';

  final String collection;
  final String entityId;
  final String field;
  final Hlc hlc;
  final String digest;

  /// True when the page shows no place for this field, so the value travels here.
  final bool hasCarriedValue;
  final Object? carriedValue;

  bool get isTombstone => field == tombstoneField;

  List<Object?> toJson() => [
        collection,
        entityId,
        field,
        hlc.toJson(),
        digest,
        if (hasCarriedValue) carriedValue,
      ];

  static BlockEntry fromJson(List<Object?> raw) => BlockEntry(
        collection: raw[0]! as String,
        entityId: raw[1]! as String,
        field: raw[2]! as String,
        hlc: Hlc.fromJson(raw[3]),
        digest: raw[4]! as String,
        hasCarriedValue: raw.length > 5,
        carriedValue: raw.length > 5 ? raw[5] : null,
      );
}

/// One line of the checklist.
class ChecklistLine {
  const ChecklistLine({required this.done, required this.text});

  final bool done;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is ChecklistLine && other.done == done && other.text == text;

  @override
  int get hashCode => Object.hash(done, text);
}

/// What a page says. Frontmatter values are a string or a list of strings; a key
/// with no value is absent, never an empty string.
class PageModel {
  const PageModel({
    required this.frontmatter,
    required this.notes,
    required this.checklist,
    required this.block,
  });

  /// In the order they are written.
  final Map<String, Object> frontmatter;

  /// Everything between the frontmatter and the final `## Actions` heading.
  final String notes;
  final List<ChecklistLine> checklist;

  /// Null when the page has no usable block: absent, mangled, or written by a
  /// newer version this code does not know.
  final List<BlockEntry>? block;
}

/// Why a page could not be read.
class PageParseException implements Exception {
  PageParseException(this.message);
  final String message;
  @override
  String toString() => 'PageParseException: $message';
}

/// A short digest of a field value: the first eight bytes of SHA-256 over its
/// JSON, in hex.
String digestOf(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).bytes
        .take(8)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();

// --- rendering ---------------------------------------------------------------

String renderPage(PageModel page) {
  final out = StringBuffer('---\n');
  for (final entry in page.frontmatter.entries) {
    out.write('${entry.key}: ${_renderScalarOrList(entry.value)}\n');
  }
  out
    ..write('---\n')
    ..write(page.notes)
    ..write('\n$_actionsHeading\n');
  for (final line in page.checklist) {
    out.write('- [${line.done ? 'x' : ' '}] ${_escapeChecklistText(line.text)}\n');
  }
  final block = page.block;
  if (block != null) {
    out
      ..write('\n')
      ..write(_renderBlock(block));
  }
  return out.toString();
}

final RegExp _plainScalar = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 _./:+-]*$');
// A colon followed by a space, or ending the text, makes a plain scalar a mapping key.
final RegExp _colonBreaksPlain = RegExp(r': |:$');
// A number, exponent forms included: a strict YAML reader types `1e5` as a float.
final RegExp _numberLike = RegExp(r'^[0-9.+-]+([eE][+-]?[0-9]+)?$');
const Set<String> _reservedWords = {'true', 'false', 'null', 'yes', 'no', 'on', 'off'};

String _renderScalarOrList(Object value) {
  if (value is List) return jsonEncode(value);
  final text = value as String;
  final plain = _plainScalar.hasMatch(text) &&
      !text.endsWith(' ') &&
      !_colonBreaksPlain.hasMatch(text) &&
      !_numberLike.hasMatch(text) &&
      !_reservedWords.contains(text.toLowerCase());
  return plain ? text : jsonEncode(text);
}

String _renderBlock(List<BlockEntry> entries) {
  final sorted = [...entries]..sort((a, b) {
      final byCollection = a.collection.compareTo(b.collection);
      if (byCollection != 0) return byCollection;
      final byEntity = a.entityId.compareTo(b.entityId);
      if (byEntity != 0) return byEntity;
      return a.field.compareTo(b.field);
    });
  final payload = base64.encode(utf8.encode(jsonEncode({
    'v': pageBlockVersion,
    'e': [for (final entry in sorted) entry.toJson()],
  })));
  final out = StringBuffer('$_blockOpen$pageBlockVersion\n$_blockNotice\n');
  for (var start = 0; start < payload.length; start += 76) {
    final end = start + 76 < payload.length ? start + 76 : payload.length;
    out.write('${payload.substring(start, end)}\n');
  }
  out.write('-->\n');
  return out.toString();
}

// --- parsing -----------------------------------------------------------------

/// Read a page. Throws [PageParseException] when the frontmatter or the final
/// heading is missing; a block that cannot be used is [PageModel.block] null, not
/// an error.
PageModel parsePage(String text) {
  final normalised = text.replaceAll('\r\n', '\n');
  if (!normalised.startsWith('---\n')) {
    throw PageParseException('no frontmatter');
  }
  final frontmatterEnd = normalised.indexOf('\n---\n', 3);
  if (frontmatterEnd < 0) throw PageParseException('frontmatter is not closed');
  final frontmatter = _parseFrontmatter(normalised.substring(4, frontmatterEnd + 1));
  var rest = normalised.substring(frontmatterEnd + 5);

  List<BlockEntry>? block;
  final blockStart = rest.lastIndexOf('\n$_blockOpen');
  if (blockStart >= 0 || rest.startsWith(_blockOpen)) {
    final from = blockStart >= 0 ? blockStart + 1 : 0;
    block = _parseBlock(rest.substring(from));
    rest = rest.substring(0, blockStart >= 0 ? blockStart : 0);
  }

  final headingAt = rest.lastIndexOf('\n$_actionsHeading\n');
  final headingAtEnd = rest.endsWith('\n$_actionsHeading');
  if (headingAt < 0 && !headingAtEnd) {
    throw PageParseException('no "$_actionsHeading" heading');
  }
  final notes = rest.substring(0, headingAt >= 0 ? headingAt : rest.length - _actionsHeading.length - 1);
  final listText =
      headingAt >= 0 ? rest.substring(headingAt + _actionsHeading.length + 2) : '';
  return PageModel(
    frontmatter: frontmatter,
    notes: notes,
    checklist: _parseChecklist(listText),
    block: block,
  );
}

Map<String, Object> _parseFrontmatter(String body) {
  final result = <String, Object>{};
  final lines = body.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (line.trim().isEmpty) continue;
    final colon = line.indexOf(':');
    if (colon <= 0) throw PageParseException('bad frontmatter line: $line');
    final key = line.substring(0, colon).trim();
    final raw = line.substring(colon + 1).trim();
    if (raw.isEmpty) {
      // An editor may write a list as a YAML block list: `key:` and then one
      // `- item` line per item. An empty value with no items is an empty field.
      final items = <String>[];
      while (index + 1 < lines.length &&
          RegExp(r'^\s*-(\s|$)').hasMatch(lines[index + 1])) {
        index++;
        final item = lines[index].trim().substring(1).trim();
        items.add(_parseScalar(key, item));
      }
      if (items.isNotEmpty) result[key] = items;
      continue;
    }
    if (raw == 'null' || raw == '~') continue;
    if (raw.startsWith('[')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List && decoded.every((item) => item is String)) {
          result[key] = decoded.cast<String>();
        } else {
          throw const FormatException('not a list of strings');
        }
      } on FormatException catch (error) {
        throw PageParseException('bad value for $key: ${error.message}');
      }
    } else {
      result[key] = _parseScalar(key, raw);
    }
  }
  return result;
}

/// One scalar: double-quoted (JSON), single-quoted (YAML, `''` is a quote) or
/// plain.
String _parseScalar(String key, String raw) {
  if (raw.startsWith('"')) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is String) return decoded;
      throw const FormatException('not a string');
    } on FormatException catch (error) {
      throw PageParseException('bad value for $key: ${error.message}');
    }
  }
  if (raw.length >= 2 && raw.startsWith("'") && raw.endsWith("'")) {
    return raw.substring(1, raw.length - 1).replaceAll("''", "'");
  }
  return raw;
}

/// A checklist line holds one line of text.
///
/// The pattern takes a retained carriage return as part of the text: `.` does
/// not match a line terminator by default, and a line that ended in one would
/// be refused whole — which reads back as a line that was never there.
final RegExp _checklistLine = RegExp(r'^- \[([ xX])\] ?(.*)$', dotAll: true);

List<ChecklistLine> _parseChecklist(String text) {
  final lines = <ChecklistLine>[];
  for (final line in text.split('\n')) {
    final match = _checklistLine.firstMatch(line);
    if (match == null) continue;
    lines.add(ChecklistLine(
      done: match.group(1) != ' ',
      text: _unescapeChecklistText(match.group(2)!),
    ));
  }
  return lines;
}

/// A checklist line holds one line of text.
///
/// A text that spans lines is written with its line ends spelled out (`\n` for
/// a line feed, `\r` for a carriage return), so the line stays one line and
/// the text survives the page: a line that was cut short would read back as a
/// different Action. The spelling is reversible, so the text that goes in
/// comes back out unchanged.
String _escapeChecklistText(String text) => text
    .replaceAll('\\', '\\\\')
    .replaceAll('\r', '\\r')
    .replaceAll('\n', '\\n');

/// The inverse of [_escapeChecklistText].
String _unescapeChecklistText(String text) {
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final character = text[i];
    if (character != '\\' || i + 1 == text.length) {
      out.write(character);
      continue;
    }
    final next = text[i + 1];
    if (next == 'n') {
      out.write('\n');
      i++;
    } else if (next == 'r') {
      out.write('\r');
      i++;
    } else if (next == '\\') {
      out.write('\\');
      i++;
    } else {
      out.write(character);
    }
  }
  return out.toString();
}

List<BlockEntry>? _parseBlock(String text) {
  final lines = text.split('\n');
  final header = lines.first.substring(_blockOpen.length).trim();
  if (int.tryParse(header) != pageBlockVersion) return null;
  final close = lines.indexOf('-->');
  if (close < 2) return null;
  try {
    final payload = lines.sublist(2, close).join();
    final decoded = jsonDecode(utf8.decode(base64.decode(payload)));
    if (decoded is! Map || decoded['v'] != pageBlockVersion) return null;
    return [
      for (final raw in decoded['e']! as List)
        BlockEntry.fromJson((raw as List).cast<Object?>()),
    ];
  } on Object {
    return null;
  }
}
