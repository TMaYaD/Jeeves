import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/inbox/inbox_screen.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();
  runApp(const ProviderScope(child: JeevesApp()));
}

class JeevesApp extends StatelessWidget {
  const JeevesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jeeves',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2667B7),
        useMaterial3: true,
      ),
      home: const InboxScreen(),
    );
  }
}
