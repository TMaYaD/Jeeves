import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../providers/tags_provider.dart';

/// The words and the mark the picker shows for one tag type.
class _PickerCopy {
  const _PickerCopy({
    required this.emptyLabel,
    required this.selectTitle,
    required this.removeLabel,
    required this.newLabel,
    required this.nameHint,
    required this.icon,
    required this.rowIcon,
  });

  /// What the closed picker reads when nothing is assigned.
  final String emptyLabel;

  /// The dialog's title.
  final String selectTitle;

  /// The row that clears the assignment.
  final String removeLabel;

  /// The button that creates a tag of this type.
  final String newLabel;

  /// The hint of the name field.
  final String nameHint;

  /// The mark in front of the closed picker.
  final IconData icon;

  /// The mark in front of one row of the dialog.
  final IconData rowIcon;
}

/// The copy for the tag types the app offers today. A type with no entry
/// falls back to its own name, capitalised.
const _kPickerCopyByType = <String, _PickerCopy>{
  'project': _PickerCopy(
    emptyLabel: 'No project',
    selectTitle: 'Select project',
    removeLabel: 'Remove project',
    newLabel: 'New project',
    nameHint: 'Project name',
    icon: Icons.folder_outlined,
    rowIcon: Icons.folder,
  ),
  // The Area's mark is provisional: the design boards that fix it have not
  // reached engineering yet.
  'area': _PickerCopy(
    emptyLabel: 'No Area',
    selectTitle: 'Select Area',
    removeLabel: 'Remove Area',
    newLabel: 'New Area',
    nameHint: 'Area name',
    icon: Icons.explore_outlined,
    rowIcon: Icons.explore,
  ),
};

_PickerCopy _copyFor(String tagType) {
  final known = _kPickerCopyByType[tagType];
  if (known != null) return known;
  final label = tagType.isEmpty
      ? 'tag'
      : '${tagType[0].toUpperCase()}${tagType.substring(1)}';
  return _PickerCopy(
    emptyLabel: 'No $label',
    selectTitle: 'Select $label',
    removeLabel: 'Remove $label',
    newLabel: 'New $label',
    nameHint: '$label name',
    icon: Icons.sell_outlined,
    rowIcon: Icons.sell_outlined,
  );
}

/// Displays the tag of one [tagType] and opens a dialog to change it.
///
/// It is the Outcome Project row today; the tag type decides which tags it
/// offers and how it reads, so a habit's Area reuses it unchanged.
class ProjectPickerWidget extends ConsumerWidget {
  const ProjectPickerWidget({
    super.key,
    required this.currentTag,
    required this.onAssign,
    required this.onClear,
    this.customChild,
    this.tagType = 'project',
  });

  /// The assigned tag of [tagType], or null if none.
  final Tag? currentTag;

  /// Called with the selected [Tag] when the user picks or creates a tag.
  final ValueChanged<Tag> onAssign;

  /// Called when the user removes the tag.
  final VoidCallback onClear;

  /// Optional custom child widget to display instead of the default styled container.
  final Widget? customChild;

  /// The tag type this picker chooses among (`project`, `area`, …).
  final String tagType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final copy = _copyFor(tagType);
    // The project rows keep their own provider, so every Outcome surface
    // reads exactly the tags it read before the picker grew a tag type.
    final tagsAsync = tagType == 'project'
        ? ref.watch(projectTagsProvider)
        : ref.watch(tagsByTypeProvider(tagType));

    return InkWell(
      onTap: () => _showPicker(context, ref, tagsAsync.asData?.value ?? []),
      borderRadius: BorderRadius.circular(8),
      child: customChild ??
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFE5E7EB)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(copy.icon, size: 18, color: const Color(0xFF6B7280)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    currentTag?.name ?? copy.emptyLabel,
                    style: TextStyle(
                      color: currentTag != null
                          ? const Color(0xFF1A1A2E)
                          : const Color(0xFF9CA3AF),
                    ),
                  ),
                ),
                const Icon(Icons.arrow_drop_down, color: Color(0xFF9CA3AF)),
              ],
            ),
          ),
    );
  }

  Future<void> _showPicker(
    BuildContext context,
    WidgetRef ref,
    List<Tag> tags,
  ) async {
    // Read before the dialog await: the picker (e.g. in a bulk-selection bar)
    // can be disposed while the dialog is open, which invalidates `ref`.
    final tagNotifier = ref.read(tagNotifierProvider);
    final result = await showDialog<_ProjectPickerResult>(
      context: context,
      builder: (ctx) => _ProjectPickerDialog(
        tags: tags,
        currentId: currentTag?.id,
        copy: _copyFor(tagType),
      ),
    );
    if (result == null) return;
    if (result.clear) {
      onClear();
    } else if (result.tag != null) {
      onAssign(result.tag!);
    } else if (result.newName != null) {
      final tag = await tagNotifier.createTag(result.newName!, tagType);
      onAssign(tag);
    }
  }
}

class _ProjectPickerResult {
  const _ProjectPickerResult.select(this.tag)
      : clear = false,
        newName = null;
  const _ProjectPickerResult.create(this.newName)
      : tag = null,
        clear = false;
  const _ProjectPickerResult.none()
      : tag = null,
        newName = null,
        clear = true;

  final Tag? tag;
  final String? newName;
  final bool clear;
}

class _ProjectPickerDialog extends StatefulWidget {
  const _ProjectPickerDialog({
    required this.tags,
    required this.copy,
    this.currentId,
  });

  final List<Tag> tags;
  final _PickerCopy copy;
  final String? currentId;

  @override
  State<_ProjectPickerDialog> createState() => _ProjectPickerDialogState();
}

class _ProjectPickerDialogState extends State<_ProjectPickerDialog> {
  final _newTagController = TextEditingController();
  bool _creatingNew = false;

  @override
  void dispose() {
    _newTagController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.copy.selectTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Tag list in a bounded scrollable area so the dialog does not
            // overflow when the tag count grows beyond the viewport.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.4,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.currentId != null)
                      ListTile(
                        leading: const Icon(Icons.clear),
                        title: Text(widget.copy.removeLabel),
                        onTap: () => Navigator.of(context)
                            .pop(const _ProjectPickerResult.none()),
                      ),
                    for (final tag in widget.tags)
                      ListTile(
                        leading: Icon(
                          widget.copy.rowIcon,
                          color: tag.id == widget.currentId
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        title: Text(tag.name),
                        onTap: () => Navigator.of(context)
                            .pop(_ProjectPickerResult.select(tag)),
                      ),
                  ],
                ),
              ),
            ),
            if (_creatingNew)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextField(
                  controller: _newTagController,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: widget.copy.nameHint,
                    border: const OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onSubmitted: (value) {
                    final name = value.trim();
                    if (name.isNotEmpty) {
                      Navigator.of(context)
                          .pop(_ProjectPickerResult.create(name));
                    }
                  },
                ),
              )
            else
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: Text(widget.copy.newLabel),
                onPressed: () => setState(() => _creatingNew = true),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (_creatingNew)
          FilledButton(
            onPressed: () {
              final name = _newTagController.text.trim();
              if (name.isNotEmpty) {
                Navigator.of(context)
                    .pop(_ProjectPickerResult.create(name));
              }
            },
            child: const Text('Create'),
          ),
      ],
    );
  }
}
