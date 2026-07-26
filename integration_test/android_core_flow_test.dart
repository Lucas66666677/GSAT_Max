import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:gsat_max/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Run with --dart-define=GSAT_MAX_DISABLE_PERMISSION_PROMPTS=true. Native
  // notification denial is exercised separately through adb during RC smoke.

  testWidgets('Android Closed Beta local core flow', (tester) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final email = 'android.rc.$timestamp@example.com';
    const password = 'BetaPass123!';

    await app.main();
    await _pumpUntil(tester, find.byType(app.LoginScreen));

    await tester.tap(find.text('建立新帳號'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), 'Android RC Student');
    await tester.enterText(fields.at(1), email);
    await tester.enterText(fields.at(2), password);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '建立帳號'));

    await _pumpUntil(tester, find.byType(app.OnboardingScreen), seconds: 20);
    for (final answer in const [
      'important',
      'She has studied English for three years.',
      'continued over time',
      'The student who won the prize is my classmate.',
      'explain what the data shows',
    ]) {
      await _pumpUntil(tester, find.text(answer));
      await tester.tap(find.text(answer));
      await tester.pump(const Duration(milliseconds: 550));
    }

    await _pumpUntil(tester, find.byType(app.HomeScreen), seconds: 25);
    expect(find.text('首頁'), findsOneWidget);

    await _setTargetExamDate(tester);
    await _openBottomTab(tester, '首頁');
    await _completeFirstMissionAndReviewCard(tester);

    final restartContext = tester.element(find.byType(app.GsatEnglishApp));
    app.AppRestartScope.restartApp(restartContext);
    await tester.pump();
    await _pumpUntil(tester, find.byType(app.HomeScreen), seconds: 20);

    await _openBottomTab(tester, '診斷');
    await tester.tap(find.text('開始測驗'));
    await _pumpUntil(tester, find.byType(app.GrammarQuizScreen));
    await tester.pageBack();
    await _pumpUntil(tester, find.byType(app.DiagnosticScreen));
    await tester.tap(find.text('開啟錯題本'));
    await _pumpUntil(tester, find.byType(app.ErrorLedgerScreen));
    await tester.pageBack();

    await _openBottomTab(tester, '閱讀');
    expect(find.byType(app.ReadingVocabScreen), findsOneWidget);
    await _openBottomTab(tester, '寫作');
    expect(find.byType(app.WritingScreen), findsOneWidget);
    await _openBottomTab(tester, '個人');
    expect(find.byType(app.ProfileScreen), findsOneWidget);

    await tester.tap(find.byTooltip('登出'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '登出'));
    await _pumpUntil(tester, find.byType(app.LoginScreen), seconds: 15);
    final loginFields = find.byType(TextField);
    await tester.enterText(loginFields.at(0), email);
    await tester.enterText(loginFields.at(1), password);
    await tester.tap(find.widgetWithText(FilledButton, '開始練習'));
    await _pumpUntil(tester, find.byType(app.HomeScreen), seconds: 20);
  });
}

Future<void> _setTargetExamDate(WidgetTester tester) async {
  await _openBottomTab(tester, '個人');
  await _pumpUntil(tester, find.byTooltip('設定'), seconds: 15);
  await tester.tap(find.byTooltip('設定'));
  await _pumpUntil(tester, find.byType(app.SettingsScreen));
  await _pumpUntil(tester, find.text('學測目標日期'), seconds: 15);
  await tester.tap(find.text('學測目標日期'));
  await _pumpUntil(tester, find.byType(DatePickerDialog));
  final confirm = find.text('確定');
  await tester.tap(confirm.evaluate().isNotEmpty ? confirm : find.text('OK'));
  await tester.pump(const Duration(seconds: 2));
  await tester.pageBack();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _completeFirstMissionAndReviewCard(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  final mission = find.byIcon(Icons.radio_button_unchecked_rounded);
  if (mission.evaluate().isNotEmpty) {
    await tester.tap(mission.first);
    await tester.pump(const Duration(milliseconds: 700));
  }

  final card = find.byType(app.FlashcardView);
  if (card.evaluate().isNotEmpty) {
    await tester.tap(card.first);
    await tester.pump(const Duration(milliseconds: 700));
    final good = find.text('記得（1 天）');
    if (good.evaluate().isNotEmpty) {
      await tester.tap(good);
      await tester.pump(const Duration(seconds: 1));
    }
  }
}

Future<void> _openBottomTab(WidgetTester tester, String label) async {
  await _pumpUntil(tester, find.text(label));
  await tester.tap(find.text(label).last);
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int seconds = 10,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(finder, findsWidgets);
}
