import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gsat_max/core/theme/lucirel_theme.dart';

void main() {
  test('Lucirel theme exposes the canonical product colors', () {
    final theme = buildLucirelTheme(focusMode: false);

    expect(theme.scaffoldBackgroundColor, LucirelColors.background);
    expect(theme.colorScheme.primary, LucirelColors.primary);
    expect(theme.colorScheme.secondary, LucirelColors.secondary);
  });

  testWidgets('product brand renders the Wave Gate endorsement',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLucirelTheme(focusMode: false),
        home: const Scaffold(body: LucirelProductBrand()),
      ),
    );

    expect(find.bySemanticsLabel('Lucirel Wave Gate'), findsOneWidget);
    expect(find.text('GSAT Max'), findsOneWidget);
    expect(find.textContaining('by Lucirel'), findsOneWidget);
  });
}
