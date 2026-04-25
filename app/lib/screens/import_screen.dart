import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/import_provider.dart';

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
                '${r.skippedCount > 0 ? ' (${r.skippedCount} skipped)' : ''}',
              ),
              backgroundColor: Colors.green[700],
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
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    final bytes = picked.bytes;
    if (bytes == null) return;
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
      appBar: AppBar(
        title: const Text('Import from Nirvana'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1A1A2E),
        elevation: 0,
        centerTitle: false,
      ),
      backgroundColor: const Color(0xFFF9FAFB),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _FormatInfoCard(
            icon: Icons.table_chart_outlined,
            title: 'CSV Export',
            description: 'Export from Nirvana via Settings → Export → CSV. '
                'Tasks, projects and tags are fully supported.',
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
            const LinearProgressIndicator(
              color: Color(0xFF2563EB),
              backgroundColor: Color(0xFFDBEAFE),
            ),
            const SizedBox(height: 8),
            const Center(
              child: Text('Importing…',
                  style: TextStyle(color: Color(0xFF6B7280))),
            ),
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
          const Row(
            children: [
              Icon(Icons.check_circle, color: Color(0xFF16A34A), size: 20),
              SizedBox(width: 8),
              Text('Import complete',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: Color(0xFF15803D))),
            ],
          ),
          const SizedBox(height: 12),
          _SummaryRow(label: 'Tasks imported', value: result.importedCount),
          _SummaryRow(label: 'Projects created', value: result.projectTagsCreated),
          if (result.skippedCount > 0)
            _SummaryRow(label: 'Items skipped', value: result.skippedCount),
        ],
      ),
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
