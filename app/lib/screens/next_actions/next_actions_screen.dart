import 'package:flutter/material.dart';

import '../../providers/gtd_lists_provider.dart';
import '../common/gtd_list_screen.dart';

class NextActionsScreen extends StatelessWidget {
  const NextActionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GtdListScreen(
      title: 'Next Actions',
      provider: nextActionsProvider,
    );
  }
}
