import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gsat_max/core/config/app_config.dart';
import 'package:gsat_max/main.dart';

void main() {
  test('AppConfig builds normalized API URIs', () {
    final uri = AppConfig.apiUri('health');
    expect(uri.path, '/health');
    expect(uri.hasScheme, isTrue);
  });

  test('Writing evaluation DTO preserves backend scores and corrections', () {
    final evaluation = WritingEvaluationData.fromJson({
      'total_score': 16.5,
      'max_score': 20,
      'scores': {
        'content': 4.5,
        'organization': 4,
        'grammar': 3.5,
        'vocabulary': 4.5,
      },
      'spelling_and_punctuation_issues': [],
      'corrections': [
        {
          'category': 'grammar',
          'original_sentence': 'She go to school.',
          'corrected_sentence': 'She goes to school.',
          'reason': 'Use third-person singular agreement.',
        },
      ],
      'strengths': ['Clear thesis'],
      'priority_improvements': ['Check agreement'],
      'suggested_template': ['Opening', 'Evidence', 'Conclusion'],
      'advanced_vocabulary_alternatives': [
        {
          'original': 'important',
          'advanced': 'essential',
          'usage_note': 'Use for a necessary condition.',
        },
      ],
      'demonstration': 'A polished model paragraph.',
      'rubric_version': 'gsat-writing-v1',
    });

    expect(evaluation.totalScore, 16.5);
    expect(evaluation.scores.grammar, 3.5);
    expect(
        evaluation.corrections.single.correctedSentence, 'She goes to school.');
    expect(evaluation.vocabularyAlternatives.single.advanced, 'essential');
  });

  testWidgets('Grammar skeleton renders as a stable loading surface',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: GrammarSkeleton()),
        ),
      ),
    );
    expect(find.byType(GrammarSkeleton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
