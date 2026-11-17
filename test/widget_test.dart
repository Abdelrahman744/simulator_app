import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:resilient_app/main.dart';

void main() {
  testWidgets('shows the resilient app controls', (WidgetTester tester) async {
    await tester.pumpWidget(const ResilientApp());
    await tester.pump();

    expect(find.text('Resilient App Lab'), findsOneWidget);
    expect(find.text('Server mode:'), findsOneWidget);
    expect(find.text('Load'), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsOneWidget);
  });
}
