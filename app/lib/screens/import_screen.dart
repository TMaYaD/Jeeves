import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/import_provider.dart';
import '../widgets/app_title_bar/app_title_bar.dart';
import '../widgets/capture/capture_action.dart';

class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  Uint8List? _selectedBytes;
  String? _selectedFileName;
  ProviderSubscription<ImportState>? _importSubscription;

  @override
  void initState() {
    super.initState();
    _importSubscription = ref.listenManual<ImportState>(
      importNotifierProvider,
      (previous, next) {
        if (next.result != null && previous?.result == null) {
          final r = next.result!;
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Imported ${r.importedCount} tasks'
                '${r.projectTagsCreated > 0 ? ', ${r.projectTagsCreated} projects created' : ''}'
                '${r.skippedCount > 0 ? ' (${r.skippedCount} skipped)' : ''}'
                '${r.failedRecords.isNotEmpty ? ' — ${r.failedRecords.length} left out' : ''}',
              ),
              backgroundColor:
                  r.failedRecords.isEmpty ? Colors.green[700] : Colors.amber[800],
            ),
          );
        }
      },
    );
  }

  @override
  void dispose() {
    _importSubscription?.close();
    super.dispose();
  }

  String _detectedFormat(String filename) {
    if (filename.toLowerCase().endsWith('.json')) return 'json';
    if (filename.toLowerCase().endsWith('.csv')) return 'csv';
    return 'auto';
  }

  Future<void> _pickFile() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['csv', 'json'],
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      _selectedBytes = bytes;
      _selectedFileName = picked.name;
    });
    ref.read(importNotifierProvider.notifier).reset();
  }

  Future<void> _import() async {
    if (_selectedBytes == null || _selectedFileName == null) return;
    final format = _detectedFormat(_selectedFileName!);
    await ref
        .read(importNotifierProvider.notifier)
        .importFile(_selectedBytes!, _selectedFileName!, format);
  }

  @override
  Widget build(BuildContext context) {
    final importState = ref.watch(importNotifierProvider);

    return Scaffold(
      appBar: AppTitleBar(
        title: 'Import from Nirvana',
        pinnedAction: captureAction(context),
      ),
      backgroundColor: const Color(0xFFF9FAFB),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _FormatInfoCard(
            icon: Icons.table_chart_outlined,
            title: 'CSV Export',
            description: 'Export from Nirvana via Settings → Export → CSV. '
                'Tasks, projects and labels are fully supported.',
          ),
          const SizedBox(height: 12),
          _FormatInfoCard(
            icon: Icons.data_object,
            title: 'JSON Export',
            description: 'Export from Nirvana via Settings → Export → JSON. '
                'Cancelled and deleted items are skipped automatically.',
          ),
          const SizedBox(height: 32),
          OutlinedButton.icon(
            onPressed: importState.isLoading ? null : _pickFile,
            icon: const Icon(Icons.upload_file),
            label: const Text('Choose file'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              side: const BorderSide(color: Color(0xFF2563EB)),
              foregroundColor: const Color(0xFF2563EB),
            ),
          ),
          if (_selectedFileName != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFBFDBFE)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.insert_drive_file_outlined,
                      color: Color(0xFF2563EB), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _selectedFileName!,
                      style: const TextStyle(
                          fontWeight: FontWeight.w500, color: Color(0xFF1D4ED8)),
                    ),
                  ),
                  Text(
                    _detectedFormat(_selectedFileName!).toUpperCase(),
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF6B7280)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          if (importState.isLoading) ...[
            _ImportProgressBar(importState: importState),
          ] else ...[
            FilledButton(
              onPressed: _selectedBytes != null ? _import : null,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                padding: const EdgeInsets.symmetric(vertical: 14),
                disabledBackgroundColor: const Color(0xFFD1D5DB),
              ),
              child: const Text('Import', style: TextStyle(fontSize: 16)),
            ),
          ],
          if (importState.error != null) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFECACA)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      importState.error!,
                      style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (importState.result != null) ...[
            const SizedBox(height: 20),
            _SummaryCard(result: importState.result!),
          ],
        ],
      ),
    );
  }
}

class _FormatInfoCard extends StatelessWidget {
  const _FormatInfoCard({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFF6B7280), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                const SizedBox(height: 4),
                Text(description,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF6B7280), height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.result});

  final ImportResult result;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                result.failedRecords.isEmpty
                    ? Icons.check_circle
                    : Icons.warning_amber_rounded,
                color: result.failedRecords.isEmpty
                    ? const Color(0xFF16A34A)
                    : const Color(0xFFD97706),
                size: 20,
              ),
              const SizedBox(width: 8),
              // Flexible, so a long heading wraps on a narrow screen instead
              // of overflowing it.
              Flexible(
                child: Text(
                  result.failedRecords.isEmpty
                      ? 'Import complete'
                      : 'Import finished with ${result.failedRecords.length} '
                          'record${result.failedRecords.length == 1 ? '' : 's'} '
                          'left out',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: result.failedRecords.isEmpty
                        ? const Color(0xFF15803D)
                        : const Color(0xFFB45309),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SummaryRow(label: 'Tasks imported', value: result.importedCount),
          _SummaryRow(label: 'Projects created', value: result.projectTagsCreated),
          if (result.skippedCount > 0)
            _SummaryRow(label: 'Items skipped', value: result.skippedCount),
          if (result.failedRecords.isNotEmpty) ...[
            const SizedBox(height: 12),
            _FailedRecords(failures: result.failedRecords),
          ],
        ],
      ),
    );
  }
}

/// The records an import could not take, named.
///
/// **Each one says what it was and why.** "3 records failed" is not something
/// the user can act on; the record and the reason are what they can act on.
class _FailedRecords extends StatelessWidget {
  const _FailedRecords({required this.failures});

  final List<ImportFailure> failures;

  /// How many to name. The rest are counted: a file with a thousand bad
  /// records is a story about the file, not a list to read.
  static const int _namedLimit = 10;

  @override
  Widget build(BuildContext context) {
    final named = failures.take(_namedLimit).toList();
    final rest = failures.length - named.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final failure in named)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${failure.record} — ${failure.reason}',
              style: const TextStyle(color: Color(0xFF374151), fontSize: 12),
            ),
          ),
        if (rest > 0)
          Text(
            'and $rest more',
            style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
          ),
      ],
    );
  }
}

/// The progress of a running import.
///
/// **A number that moves.** An import of a large file takes minutes, and a
/// bar that cannot say how far it has got leaves the user deciding between
/// waiting and giving up on a screen that looks exactly the same either way.
class _ImportProgressBar extends StatelessWidget {
  const _ImportProgressBar({required this.importState});

  final ImportState importState;

  @override
  Widget build(BuildContext context) {
    final progress = importState.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          value: progress?.fraction,
          color: const Color(0xFF2563EB),
          backgroundColor: const Color(0xFFDBEAFE),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            progress == null
                ? 'Importing…'
                : 'Importing ${progress.processedRows} of '
                    '${progress.totalRows} records…',
            style: const TextStyle(color: Color(0xFF6B7280)),
          ),
        ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFF374151), fontSize: 13)),
          Text('$value',
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF111827),
                  fontSize: 13)),
        ],
      ),
    );
  }
}
