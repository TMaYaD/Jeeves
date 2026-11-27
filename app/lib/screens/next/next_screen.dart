import 'package:flutter/material.dart';

import '../../providers/gtd_lists_provider.dart';
import '../../widgets/location_unknown_line.dart';
import '../common/gtd_list_screen.dart';
import 'next_empty_state.dart';

class NextScreen extends StatelessWidget {
  const NextScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GtdListScreen(
      provider: nextProvider,
      // The empty state is the Next list's own: it tells an empty Next apart
      // from one where everything is waiting for its time or its place
      // (issue #1076).
      emptyBuilder: (_) => const NextEmptyState(),
      // Each row names the Place its Outcome is at, and the list says so
      // when Jeeves does not know where the user is (issue #55).
      showPlaceName: true,
      header: const LocationUnknownLine(),
    );
  }
}
