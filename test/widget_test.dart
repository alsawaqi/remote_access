import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_access/src/services/device_daemon.dart';
import 'package:remote_access/src/ui/enrollment_screen.dart';

void main() {
  testWidgets('Enrollment screen renders its call to action', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: EnrollmentScreen(daemon: DeviceDaemon())),
    );

    expect(find.text('Enrol device'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
