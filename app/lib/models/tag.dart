import 'package:freezed_annotation/freezed_annotation.dart';

part 'tag.freezed.dart';
part 'tag.g.dart';

/// GTD tag types — mirrors the backend TAG_TYPES constant tuple.
enum TagType {
  context,
  project,
  area,
  label;

  static TagType fromString(String value) {
    return TagType.values.firstWhere(
      (t) => t.name == value,
      orElse: () => TagType.label,
    );
  }
}

@freezed
abstract class Tag with _$Tag {
  const Tag._();

  const factory Tag({
    required String id,
    required String name,
    required String type,
    String? color,
    required String userId,
  }) = _Tag;

  factory Tag.fromJson(Map<String, dynamic> json) => _$TagFromJson(json);

  /// True when this tag represents a GTD context (e.g. @office, @phone).
  bool get isContext => type == TagType.context.name;

  /// True when this tag represents a GTD project.
  bool get isProject => type == TagType.project.name;

  /// True when this tag represents a GTD area of responsibility.
  bool get isArea => type == TagType.area.name;

  /// True when this tag is a generic label.
  bool get isLabel => type == TagType.label.name;

  TagType get tagType => TagType.fromString(type);
}
