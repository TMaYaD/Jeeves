import 'package:flutter/material.dart';

import '../../providers/gtd_lists_provider.dart';
import '../common/gtd_list_screen.dart';

class ScheduledScreen extends StatelessWidget {
  const ScheduledScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GtdListScreen(
      title: 'Scheduled',
      provider: scheduledProvider,
    );
  }
}
