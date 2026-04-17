import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'providers/daily_planning_provider.dart';
import 'router.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();
  // Seed the planning-completion notifier before the router is consulted so
  // the first redirect evaluation is synchronous and correct.
  // Auth state is owned entirely by AuthNotifier to avoid a race where
  // currentUserIdProvider briefly holds 'local' before the real user ID loads.
  await initPlanningCompletion();
  runApp(const ProviderScope(child: JeevesApp()));
}

class JeevesApp extends StatelessWidget {
  const JeevesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Jeeves',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2667B7),
        useMaterial3: true,
        textTheme: GoogleFonts.interTextTheme(),
        scaffoldBackgroundColor: Colors.white,
      ),
      routerConfig: appRouter,
    );
  }
}
