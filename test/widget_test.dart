// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:astraepub/main.dart';

void main() {
  testWidgets('AstraePub load smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame using the new class name.
    await tester.pumpWidget(const AstraePubApp());

    // Verify that our app bar title 'Reading' appears on the screen.
    expect(find.text('Reading'), findsOneWidget);
    
    // Verify that the initial placeholder text is present.
    expect(find.text('Please open an EPUB file.'), findsOneWidget);
  });
}