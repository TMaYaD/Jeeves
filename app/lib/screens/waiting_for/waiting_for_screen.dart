import 'package:flutter/material.dart';

import '../../providers/gtd_lists_provider.dart';
import '../common/gtd_list_screen.dart';

class WaitingForScreen extends StatelessWidget {
  const WaitingForScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GtdListScreen(
      title: 'Waiting For',
      provider: waitingForProvider,
    );
  }
}
