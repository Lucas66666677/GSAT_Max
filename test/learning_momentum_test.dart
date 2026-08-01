import 'package:flutter_test/flutter_test.dart';
import 'package:gsat_max/main.dart';

void main() {
  test('time-budget schedule parses reward and high-success micro win', () {
    final schedule = StudyMissionSchedule.fromJson({
      'target_exam_date': '2027-01-23T00:00:00',
      'days_remaining': 120,
      'upward_curve': 0.4,
      'focus_skill': 'grammar',
      'available_minutes': 3,
      'planned_minutes': 3,
      'session_mode': 'rescue',
      'can_stop_when_complete': true,
      'encouragement': '做完就可以停。',
      'reward_summary': {
        'total_points': 145,
        'level': 2,
        'level_progress': 0.45,
        'points_to_next_level': 55,
        'weekly_active_days': 2,
        'weekly_goal_days': 5,
        'weekly_goal_progress': 0.4,
        'comeback_count': 1,
        'streak_shields': 1,
        'current_streak': 3,
        'headline': '今天已經有進步。',
      },
      'tasks': [
        {
          'id': 91,
          'task_key': 'micro_win',
          'type': 'micro_win',
          'status': 'pending',
          'priority': 'core',
          'difficulty': 'foundation',
          'success_target': 0.95,
          'reward_points': 8,
          'count': 3,
          'minutes': 1,
        },
      ],
    });

    expect(schedule.availableMinutes, 3);
    expect(schedule.plannedMinutes, lessThanOrEqualTo(3));
    expect(schedule.sessionMode, 'rescue');
    expect(schedule.canStopWhenComplete, isTrue);
    expect(schedule.tasks.single.type, 'micro_win');
    expect(schedule.tasks.single.successTarget, 0.95);
    expect(schedule.tasks.single.rewardPoints, 8);
    expect(schedule.rewardSummary?.totalPoints, 145);
    expect(schedule.rewardSummary?.weeklyActiveDays, 2);
  });

  test('reward feedback updates level and local progress deterministically',
      () {
    final summary = LearningRewardSummary.fromJson({
      'total_points': 95,
      'level': 1,
      'level_progress': 0.95,
      'points_to_next_level': 5,
      'weekly_active_days': 1,
      'weekly_goal_days': 4,
      'weekly_goal_progress': 0.25,
      'comeback_count': 0,
      'streak_shields': 1,
      'current_streak': 1,
      'headline': 'Keep going',
    });
    final feedback = LearningRewardFeedback.fromJson({
      'awarded': true,
      'points': 10,
      'message': '第一個小任務完成。',
      'total_points': 105,
      'level': 2,
      'level_up': true,
    });
    final updated = summary.apply(feedback);

    expect(updated.totalPoints, 105);
    expect(updated.level, 2);
    expect(updated.levelProgress, 0.05);
    expect(updated.pointsToNextLevel, 95);
    expect(updated.headline, '第一個小任務完成。');
  });

  test('learning preferences and paper pack payloads round-trip', () {
    final preferences = LearningPreferences.fromJson({
      'weekday_minutes': 8,
      'weekend_minutes': 18,
      'preferred_session_minutes': 10,
      'rescue_session_minutes': 3,
      'maximum_session_minutes': 25,
      'weekly_goal_days': 4,
      'gentle_streak_enabled': true,
      'paper_pack_enabled': true,
    });
    final changed = preferences.copyWith(
      weekdayMinutes: 12,
      paperPackEnabled: false,
    );
    expect(changed.toJson()['weekday_minutes'], 12);
    expect(changed.toJson()['weekend_minutes'], 18);
    expect(changed.toJson()['paper_pack_enabled'], isFalse);

    final pack = WeeklyStudyPackInfo.fromJson({
      'id': 'pack-1',
      'week_start': '2026-07-27',
      'pack_code': 'ABCD2345',
      'daily_minutes': 10,
      'status': 'ready',
      'completed_days': [1, 3],
      'pdf_url': '/user/weekly-study-pack/pack-1/pdf',
    });
    expect(pack.id, 'pack-1');
    expect(pack.packCode, 'ABCD2345');
    expect(pack.completedDays, [1, 3]);
    expect(pack.weekStart, DateTime(2026, 7, 27));
  });
}
