import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../providers/tags_provider.dart';

/// Displays the current project and opens a dialog to change it.
class ProjectPickerWidget extends ConsumerWidget {
  const ProjectPickerWidget({
    super.key,
    required this.currentProjectTag,
    required this.onAssign,
    required this.onClear,
  });

  /// The currently assigned project tag, or null if none.
  final Tag? currentProjectTag;

  /// Called with the selected [Tag] when the user picks or creates a project.
  final ValueChanged<Tag> onAssign;

  /// Called when the user removes the project.
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectsAsync = ref.watch(projectTagsProvider);

    return InkWell(
      onTap: () => _showPicker(context, ref, projectsAsync.asData?.value ?? []),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.folder_outlined, size: 18, color: Color(0xFF6B7280)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                currentProjectTag?.name ?? 'No project',
                style: TextStyle(
                  color: currentProjectTag != null
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
    List<Tag> projects,
  ) async {
    final result = await showDialog<_ProjectPickerResult>(
      context: context,
      builder: (ctx) => _ProjectPickerDialog(
        projects: projects,
        currentId: currentProjectTag?.id,
      ),
    );
    if (result == null) return;
    if (result.clear) {
      onClear();
    } else if (result.tag != null) {
      onAssign(result.tag!);
    } else if (result.newName != null) {
      final tag = await ref
          .read(tagNotifierProvider)
          .createTag(result.newName!, 'project');
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
  const _ProjectPickerDialog({required this.projects, this.currentId});

  final List<Tag> projects;
  final String? currentId;

  @override
  State<_ProjectPickerDialog> createState() => _ProjectPickerDialogState();
}

class _ProjectPickerDialogState extends State<_ProjectPickerDialog> {
  final _newProjectController = TextEditingController();
  bool _creatingNew = false;

  @override
  void dispose() {
    _newProjectController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select project'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.currentId != null)
              ListTile(
                leading: const Icon(Icons.clear),
                title: const Text('Remove project'),
                onTap: () => Navigator.of(context)
                    .pop(const _ProjectPickerResult.none()),
              ),
            for (final p in widget.projects)
              ListTile(
                leading: Icon(
                  Icons.folder,
                  color: p.id == widget.currentId
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(p.name),
                onTap: () => Navigator.of(context)
                    .pop(_ProjectPickerResult.select(p)),
              ),
            if (_creatingNew)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextField(
                  controller: _newProjectController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Project name',
                    border: OutlineInputBorder(),
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
                label: const Text('New project'),
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
              final name = _newProjectController.text.trim();
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
