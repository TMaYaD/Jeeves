import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';

import 'providers/auth_provider.dart';
import 'providers/daily_planning_provider.dart';
import 'router.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();
  // Seed both notifiers before the router is consulted so the first redirect
  // evaluation is synchronous and correct.
  await Future.wait([
    initPlanningCompletion(),
    _initAuthState(),
  ]);
  runApp(const ProviderScope(child: JeevesApp()));
}

/// Reads any persisted JWT from secure storage and sets [authStateNotifier]
/// so the router can make the correct auth redirect on first render.
Future<void> _initAuthState() async {
  const storage = FlutterSecureStorage();
  final token = await storage.read(key: 'jwt_token');
  if (token != null) {
    authStateNotifier.value = true;
  }
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
