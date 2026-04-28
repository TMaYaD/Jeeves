import 'package:flutter/material.dart';

import '../../providers/gtd_lists_provider.dart';
import '../common/gtd_list_screen.dart';

class SomedayMaybeScreen extends StatelessWidget {
  const SomedayMaybeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GtdListScreen(
      title: 'Maybe',
      provider: maybeProvider,
    );
  }
}
