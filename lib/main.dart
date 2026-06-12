import 'package:flutter/material.dart';

import 'src/services/device_daemon.dart';
import 'src/ui/dashboard_screen.dart';
import 'src/ui/enrollment_screen.dart';

final DeviceDaemon daemon = DeviceDaemon();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  daemon.bootstrap();
  runApp(const RemoteAccessApp());
}

class RemoteAccessApp extends StatelessWidget {
  const RemoteAccessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote Access Agent',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2563EB),
      ),
      home: AnimatedBuilder(
        animation: daemon,
        builder: (context, _) {
          if (daemon.phase == DaemonPhase.notEnrolled) {
            return EnrollmentScreen(daemon: daemon);
          }
          return DashboardScreen(daemon: daemon);
        },
      ),
    );
  }
}
