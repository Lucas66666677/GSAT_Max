import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:confetti/confetti.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' hide HapticFeedback;
import 'package:flutter/services.dart' as flutter_services show HapticFeedback;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

import 'core/config/app_config.dart';
import 'core/services/background_job_poller.dart';
import 'core/services/purchase_service.dart';
import 'core/services/target_exam_date_service.dart';
import 'core/storage/mission_progress_store.dart';

const Color kAppBackground = Color(0xFF121212);
const Color kSurfaceGlass = Color(0xB01B2430);
const Color kSurfaceGlassStrong = Color(0xD0202B39);
const Color kGlassBorder = Color(0x33FFFFFF);
const Color kTextPrimary = Color(0xFFF8FAFC);
const Color kTextSecondary = Color(0xFFB7C2D0);
const Color kTextTertiary = Color(0xFF8A98AA);
const Color kNeonGreen = Color(0xFF36F3A5);
const Color kElectricBlue = Color(0xFF2F80ED);
const Color kDangerRed = Color(0xFFEF4444);
const String kCachedReviewCardsKey = 'cached_due_review_cards_v1';
const String kTtsSpeechRateKey = 'settings_tts_speech_rate_v1';
const String kReminderHourKey = 'settings_daily_reminder_hour_v1';
const String kReminderMinuteKey = 'settings_daily_reminder_minute_v1';
const String kTelemetryCrashLogsKey = 'telemetry_crash_logs_v1';
const String kAppModeKey = 'settings_app_mode_v1';
const String kWeeklyReportPersonaKey = 'settings_weekly_report_persona_v1';
const double kTabletBreakpoint = 600;

enum AppMode { focus, engagement }

enum AmbientSound { lofi, rainstorm }

bool isTabletLayout(BuildContext context) {
  return MediaQuery.sizeOf(context).width > kTabletBreakpoint;
}

double tabletReadingTextScale(BuildContext context) {
  return isTabletLayout(context) ? 1.15 : 1.0;
}

String _appModeApiValue(AppMode mode) {
  return mode == AppMode.focus ? 'focus' : 'engagement';
}

String _currentAppModeApiValue = 'engagement';

class HapticFeedback {
  static bool enabled = true;

  static Future<void> lightImpact() =>
      enabled ? flutter_services.HapticFeedback.lightImpact() : Future.value();

  static Future<void> mediumImpact() =>
      enabled ? flutter_services.HapticFeedback.mediumImpact() : Future.value();

  static Future<void> heavyImpact() =>
      enabled ? flutter_services.HapticFeedback.heavyImpact() : Future.value();

  static Future<void> selectionClick() => enabled
      ? flutter_services.HapticFeedback.selectionClick()
      : Future.value();

  static Future<void> vibrate() =>
      enabled ? flutter_services.HapticFeedback.vibrate() : Future.value();
}

class TelemetryService {
  TelemetryService._();

  static final TelemetryService instance = TelemetryService._();
  static const int _maxStoredLogs = 50;

  Future<void> recordFlutterError(
    FlutterErrorDetails details, {
    bool fatal = false,
  }) {
    return recordError(
      details.exception,
      details.stack,
      source: details.library ?? 'flutter',
      fatal: fatal,
      context: details.context?.toDescription(),
    );
  }

  Future<void> recordError(
    Object error,
    StackTrace? stack, {
    required String source,
    bool fatal = false,
    String? context,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing =
          prefs.getStringList(kTelemetryCrashLogsKey) ?? <String>[];
      final entry = <String, dynamic>{
        'timestamp': DateTime.now().toIso8601String(),
        'source': source,
        'fatal': fatal,
        'error': error.toString(),
        if (context != null && context.trim().isNotEmpty) 'context': context,
        'stack': _trimStack(stack),
        'device': _deviceSnapshot(),
      };
      final updated = <String>[jsonEncode(entry), ...existing];
      await prefs.setStringList(
        kTelemetryCrashLogsKey,
        updated.take(_maxStoredLogs).toList(growable: false),
      );
    } catch (_) {
      // Telemetry should never create a second failure path.
    }
  }

  Future<List<Map<String, dynamic>>> readCrashLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final rawLogs = prefs.getStringList(kTelemetryCrashLogsKey) ?? <String>[];
    return rawLogs
        .map(_decodeJsonObject)
        .where((log) => log.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> clearCrashLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kTelemetryCrashLogsKey);
  }

  static String _trimStack(StackTrace? stack) {
    if (stack == null) return '';
    final lines = stack.toString().split('\n');
    return lines.take(18).join('\n');
  }

  static Map<String, dynamic> _deviceSnapshot() {
    if (kIsWeb) {
      return const {
        'platform': 'web',
        'platform_version': 'browser',
        'locale': 'browser',
        'processors': 0,
      };
    }
    return {
      'platform': Platform.operatingSystem,
      'platform_version': Platform.operatingSystemVersion,
      'locale': Platform.localeName,
      'processors': Platform.numberOfProcessors,
    };
  }
}

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();
  static const int _dailyReviewNotificationId = 820;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  bool _permissionsRequested = false;

  Future<void> initialize() async {
    if (_isInitialized) return;

    tz.initializeTimeZones();
    try {
      final localTimeZone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(localTimeZone));
    } catch (_) {
      // Fall back to the timezone package default if the platform timezone is unavailable.
    }
    final initializationSettings = InitializationSettings(
      android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );

    await _plugin.initialize(initializationSettings);
    _isInitialized = true;
  }

  Future<void> requestPermissionsGracefully() async {
    if (_permissionsRequested) return;
    _permissionsRequested = true;

    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {
      // Permission prompts vary by platform/version; auth should never fail because of this.
    }
  }

  Future<void> scheduleDailyReviewReminder({
    bool startTomorrow = false,
    int? hour,
    int? minute,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final reminderHour = hour ?? prefs.getInt(kReminderHourKey) ?? 20;
      final reminderMinute = minute ?? prefs.getInt(kReminderMinuteKey) ?? 0;
      await _plugin.zonedSchedule(
        _dailyReviewNotificationId,
        '🔥 Don\'t lose your streak!',
        'You have vocabulary words waiting to be reviewed. Keep your GSAT English sharp!',
        _nextReminderTime(
          startTomorrow: startTomorrow,
          hour: reminderHour,
          minute: reminderMinute,
        ),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'daily_review_reminders',
            'Daily Review Reminders',
            channelDescription:
                'Evening reminders for vocabulary review and streak protection.',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (_) {
      // Scheduling may fail on unsupported emulators or denied permission; keep UX flowing.
    }
  }

  Future<void> cancelTodaysReviewReminder() async {
    try {
      await _plugin.cancel(_dailyReviewNotificationId);
      await scheduleDailyReviewReminder(startTomorrow: true);
    } catch (_) {
      // No-op: cancellation should be silent if the platform plugin is unavailable.
    }
  }

  Future<void> rescheduleDailyReviewReminder({
    required int hour,
    required int minute,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kReminderHourKey, hour);
    await prefs.setInt(kReminderMinuteKey, minute);
    await _plugin.cancel(_dailyReviewNotificationId);
    await scheduleDailyReviewReminder(hour: hour, minute: minute);
  }

  tz.TZDateTime _nextReminderTime({
    required bool startTomorrow,
    required int hour,
    required int minute,
  }) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour.clamp(0, 23).toInt(),
      minute.clamp(0, 59).toInt(),
    );

    if (startTomorrow || !scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    return scheduled;
  }
}

class AudioService {
  AudioService._();

  static final AudioService instance = AudioService._();

  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _ambientPlayer = AudioPlayer();
  bool _isConfigured = false;
  double _speechRate = 0.42;
  VoidCallback? _onComplete;
  void Function(String message)? _onError;
  AmbientSound? _activeAmbientSound;
  bool _isAmbientLooping = false;

  double get speechRate => _speechRate;
  AmbientSound? get activeAmbientSound => _activeAmbientSound;
  bool get isAmbientLooping => _isAmbientLooping;

  Future<void> initialize() async {
    if (_isConfigured) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      _speechRate = prefs.getDouble(kTtsSpeechRateKey) ?? _speechRate;
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(_speechRate);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      await _tts.awaitSpeakCompletion(false);
      _tts.setCompletionHandler(() => _onComplete?.call());
      _tts.setCancelHandler(() => _onComplete?.call());
      _tts.setErrorHandler((message) {
        _onError?.call(message.toString());
        _onComplete?.call();
      });
      _isConfigured = true;
    } catch (error) {
      throw StateError('Text-to-speech is unavailable on this device.');
    }
  }

  Future<void> setSpeechRate(double value, {bool persist = true}) async {
    await initialize();
    _speechRate = value.clamp(0.1, 1.0).toDouble();
    await _tts.setSpeechRate(_speechRate);
    if (persist) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(kTtsSpeechRateKey, _speechRate);
    }
  }

  Future<void> speak(
    String text, {
    VoidCallback? onComplete,
    void Function(String message)? onError,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    await initialize();
    try {
      await _tts.stop();
      _onComplete = onComplete;
      _onError = onError;
      final result = await _tts.speak(trimmed);
      if (result == 0 || result == false) {
        throw StateError('Text-to-speech could not start.');
      }
    } catch (error) {
      _onComplete?.call();
      rethrow;
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Some emulators report stop as unavailable; UI should still recover.
    } finally {
      _onComplete?.call();
    }
  }

  Future<void> playAmbientLoop(AmbientSound sound) async {
    await initialize();
    _activeAmbientSound = sound;
    _isAmbientLooping = true;
    final source = switch (sound) {
      AmbientSound.lofi => 'audio/lofi_loop.wav',
      AmbientSound.rainstorm => 'audio/rainstorm_loop.wav',
    };
    await _ambientPlayer.setReleaseMode(ReleaseMode.loop);
    await _ambientPlayer.setVolume(0.42);
    await _ambientPlayer.stop();
    await _ambientPlayer.play(AssetSource(source));
  }

  Future<void> stopAmbientLoop() async {
    _activeAmbientSound = null;
    _isAmbientLooping = false;
    try {
      await _ambientPlayer.stop();
    } catch (_) {
      // Ambient playback is optional; timer UX should keep working.
    }
  }
}

Future<void> main() async {
  await runZonedGuarded<Future<void>>(
    () async {
      final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
      FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        unawaited(
          TelemetryService.instance.recordFlutterError(details, fatal: true),
        );
      };

      ui.PlatformDispatcher.instance.onError = (error, stack) {
        unawaited(
          TelemetryService.instance.recordError(
            error,
            stack,
            source: 'platform_dispatcher',
            fatal: true,
          ),
        );
        return true;
      };

      ErrorWidget.builder = (details) {
        unawaited(
          TelemetryService.instance.recordFlutterError(details, fatal: true),
        );
        return const SystemAnomalyFallback();
      };

      try {
        await NotificationService.instance.initialize();
      } catch (error, stack) {
        await TelemetryService.instance.recordError(
          error,
          stack,
          source: 'notification_initialization',
        );
      }
      unawaited(AudioService.instance.initialize().catchError((_) {}));
      runApp(
        const AppRestartScope(
          child: ProviderScope(child: GsatEnglishApp()),
        ),
      );
    },
    (error, stack) {
      unawaited(
        TelemetryService.instance.recordError(
          error,
          stack,
          source: 'run_zoned_guarded',
          fatal: true,
        ),
      );
    },
  );
}

final authControllerProvider =
    ChangeNotifierProvider<AuthController>((ref) => AuthController());

final appModeControllerProvider =
    ChangeNotifierProvider<AppModeController>((ref) {
  final controller = AppModeController();
  unawaited(controller.initialize());
  return controller;
});

final rewardVFXControllerProvider =
    ChangeNotifierProvider<RewardVFXController>((ref) => RewardVFXController());

final reviewSyncControllerProvider =
    ChangeNotifierProvider<ReviewSyncController>((ref) {
  final controller = ReviewSyncController();
  unawaited(controller.initialize());
  return controller;
});

final purchaseServiceProvider = Provider<PurchaseServiceApi>(
  (ref) => PurchaseService.instance,
);

final routerProvider = Provider<GoRouter>((ref) {
  final authController = ref.watch(authControllerProvider);

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: authController,
    redirect: (context, state) {
      if (authController.isInitializing) return null;
      final isLoggedIn = authController.isLoggedIn;
      final isLoggingIn = state.matchedLocation == '/login';
      final isOnboarding = state.matchedLocation == '/onboarding';
      final isLegal = state.matchedLocation == '/legal';
      final isPasswordReset = state.matchedLocation == '/reset-password';
      final isEmailVerification = state.matchedLocation == '/verify-email';

      if (isLegal || isPasswordReset || isEmailVerification) return null;
      if (!isLoggedIn) return isLoggingIn ? null : '/login';
      if (!authController.hasCompletedOnboarding) {
        return isOnboarding ? null : '/onboarding';
      }
      if (isLoggingIn || isOnboarding) return '/home';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/grammar-quiz',
        builder: (context, state) => const GrammarQuizScreen(),
      ),
      GoRoute(
        path: '/error-ledger',
        builder: (context, state) => const ErrorLedgerScreen(),
      ),
      GoRoute(
        path: '/discourse',
        builder: (context, state) => const DiscourseScreen(),
      ),
      GoRoute(
        path: '/mixed-questions',
        builder: (context, state) => const MixedQuestionScreen(),
      ),
      GoRoute(
        path: '/translation-practice',
        builder: (context, state) => const TranslationScreen(),
      ),
      GoRoute(
        path: '/cloze-practice',
        builder: (context, state) => const ClozePracticeScreen(),
      ),
      GoRoute(
        path: '/sentence-level-up',
        builder: (context, state) => const SentenceLevelUpScreen(),
      ),
      GoRoute(
        path: '/exam-simulator',
        builder: (context, state) => const TimeAttackSimulatorScreen(),
      ),
      GoRoute(
        path: '/zen',
        builder: (context, state) => const ZenModeScreen(),
      ),
      GoRoute(
        path: '/exam-simulator/results',
        builder: (context, state) {
          final result = state.extra;
          return TimeAttackResultsScreen(
            result: result is TimeAttackResult ? result : null,
          );
        },
      ),
      GoRoute(
        path: '/paywall',
        builder: (context, state) => const PaywallScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/legal',
        builder: (context, state) => const LegalScreen(),
      ),
      GoRoute(
        path: '/reset-password',
        builder: (context, state) => PasswordResetScreen(
          token: state.uri.queryParameters['token'] ?? '',
        ),
      ),
      GoRoute(
        path: '/verify-email',
        builder: (context, state) => EmailVerificationScreen(
          token: state.uri.queryParameters['token'] ?? '',
        ),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return MainScreen(navigationShell: navigationShell);
        },
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home',
                builder: (context, state) => const HomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/diagnostic',
                builder: (context, state) => const DiagnosticScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/reading',
                builder: (context, state) => const ReadingVocabScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/writing',
                builder: (context, state) => const WritingScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/profile',
                builder: (context, state) => const ProfileScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

class PerformanceMetrics {
  const PerformanceMetrics({
    required this.totalTimeSeconds,
    required this.tokensPerSecond,
    required this.totalTokens,
  });

  final double totalTimeSeconds;
  final double tokensPerSecond;
  final int totalTokens;

  factory PerformanceMetrics.fromJson(Map<String, dynamic> json) {
    return PerformanceMetrics(
      totalTimeSeconds: _asDouble(json['total_time_seconds']),
      tokensPerSecond: _asDouble(json['tokens_per_second']),
      totalTokens: _asInt(json['total_tokens']),
    );
  }

  static PerformanceMetrics? maybeFromResponse(Map<String, dynamic> json) {
    final metrics = json['performance_metrics'];
    if (metrics is Map<String, dynamic>) {
      return PerformanceMetrics.fromJson(metrics);
    }
    if (metrics is Map) {
      return PerformanceMetrics.fromJson(Map<String, dynamic>.from(metrics));
    }
    return null;
  }

  static double _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  static int _asInt(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}

class CorrectedMistake {
  const CorrectedMistake({
    required this.originalQuestion,
    required this.correctAnswer,
    required this.explanation,
    this.studentWrongAnswer,
    this.grammarConcept,
    this.vocabWord,
  });

  final String originalQuestion;
  final String? studentWrongAnswer;
  final String correctAnswer;
  final String explanation;
  final String? grammarConcept;
  final String? vocabWord;

  factory CorrectedMistake.fromJson(Map<String, dynamic> json) {
    return CorrectedMistake(
      originalQuestion: _stringFromAny(
        json['original_question'] ?? json['question'],
        fallback: 'Scanned question',
      ),
      studentWrongAnswer: _nullableString(json['student_wrong_answer']),
      correctAnswer: _stringFromAny(
        json['correct_answer'],
        fallback: 'See explanation',
      ),
      explanation: _stringFromAny(
        json['explanation'],
        fallback: 'Review the target concept and compare both answers.',
      ),
      grammarConcept: _nullableString(json['grammar_concept']),
      vocabWord: _nullableString(json['vocab_word']),
    );
  }
}

class DailyExpansionQuestion {
  const DailyExpansionQuestion({
    required this.id,
    required this.concept,
    required this.question,
    required this.options,
    required this.correctOptionIndex,
    this.explanation,
  });

  final int id;
  final String concept;
  final String question;
  final List<String> options;
  final int correctOptionIndex;
  final String? explanation;

  factory DailyExpansionQuestion.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    final options = rawOptions is List
        ? rawOptions.map((option) => option.toString()).toList()
        : <String>[];
    return DailyExpansionQuestion(
      id: PerformanceMetrics._asInt(json['id']),
      concept: _stringFromAny(json['concept'], fallback: 'exam_mistake'),
      question:
          _stringFromAny(json['question'], fallback: 'Choose the best answer.'),
      options: options,
      correctOptionIndex:
          PerformanceMetrics._asInt(json['correct_option_index']),
      explanation: _nullableString(json['explanation']),
    );
  }
}

class MixedQuestionSet {
  const MixedQuestionSet({
    required this.textA,
    required this.textB,
    required this.multipleChoice,
    required this.shortAnswer,
    this.metrics,
  });

  final String textA;
  final String textB;
  final List<MixedMcqQuestion> multipleChoice;
  final List<MixedShortQuestion> shortAnswer;
  final PerformanceMetrics? metrics;

  factory MixedQuestionSet.fromJson(Map<String, dynamic> json) {
    final rawMcq = json['multiple_choice'];
    final rawShort = json['short_answer'];
    return MixedQuestionSet(
      textA: _stringFromAny(json['text_a'], fallback: 'Text A unavailable.'),
      textB: _stringFromAny(json['text_b'], fallback: 'Text B unavailable.'),
      multipleChoice: rawMcq is List
          ? rawMcq
              .whereType<Map>()
              .map((item) =>
                  MixedMcqQuestion.fromJson(Map<String, dynamic>.from(item)))
              .toList()
          : const [],
      shortAnswer: rawShort is List
          ? rawShort
              .whereType<Map>()
              .map((item) =>
                  MixedShortQuestion.fromJson(Map<String, dynamic>.from(item)))
              .toList()
          : const [],
      metrics: PerformanceMetrics.maybeFromResponse(json),
    );
  }
}

class MixedMcqQuestion {
  const MixedMcqQuestion({
    required this.number,
    required this.question,
    required this.options,
    required this.correctIndex,
    required this.explanation,
  });

  final int number;
  final String question;
  final List<String> options;
  final int correctIndex;
  final String explanation;

  factory MixedMcqQuestion.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    final options = rawOptions is List
        ? rawOptions.map((option) => option.toString()).toList()
        : <String>[];
    var correctIndex = PerformanceMetrics._asInt(json['correct_option_index']);
    if (correctIndex < 0 || correctIndex >= options.length) correctIndex = 0;
    return MixedMcqQuestion(
      number: PerformanceMetrics._asInt(json['number']),
      question:
          _stringFromAny(json['question'], fallback: 'Choose the best answer.'),
      options: options,
      correctIndex: correctIndex,
      explanation: _stringFromAny(json['explanation'], fallback: ''),
    );
  }
}

class MixedShortQuestion {
  const MixedShortQuestion({
    required this.number,
    required this.question,
    required this.referenceAnswer,
    required this.maxScore,
    required this.rubric,
  });

  final int number;
  final String question;
  final String referenceAnswer;
  final int maxScore;
  final String rubric;

  factory MixedShortQuestion.fromJson(Map<String, dynamic> json) {
    return MixedShortQuestion(
      number: PerformanceMetrics._asInt(json['number']),
      question:
          _stringFromAny(json['question'], fallback: 'Write a short answer.'),
      referenceAnswer: _stringFromAny(json['reference_answer'], fallback: ''),
      maxScore: PerformanceMetrics._asInt(json['max_score']) == 0
          ? 2
          : PerformanceMetrics._asInt(json['max_score']),
      rubric: _stringFromAny(json['rubric'],
          fallback: 'Partial credit for meaning and evidence.'),
    );
  }
}

class MixedShortFeedback {
  const MixedShortFeedback({
    required this.score,
    required this.maxScore,
    required this.feedback,
    this.metrics,
  });

  final int score;
  final int maxScore;
  final String feedback;
  final PerformanceMetrics? metrics;

  factory MixedShortFeedback.fromJson(Map<String, dynamic> json) {
    return MixedShortFeedback(
      score: PerformanceMetrics._asInt(json['score']),
      maxScore: PerformanceMetrics._asInt(json['max_score']),
      feedback: _stringFromAny(json['feedback'], fallback: 'Answer evaluated.'),
      metrics: PerformanceMetrics.maybeFromResponse(json),
    );
  }
}

class TranslationDeductionResult {
  const TranslationDeductionResult({
    required this.errorText,
    required this.errorType,
    required this.points,
    required this.explanation,
  });

  final String errorText;
  final String errorType;
  final double points;
  final String explanation;

  factory TranslationDeductionResult.fromJson(Map<String, dynamic> json) {
    return TranslationDeductionResult(
      errorText: _stringFromAny(json['error_text'], fallback: ''),
      errorType: _stringFromAny(json['error_type'], fallback: 'grammar'),
      points: PerformanceMetrics._asDouble(json['points']),
      explanation:
          _stringFromAny(json['explanation'], fallback: 'Deduction applied.'),
    );
  }
}

class TranslationEvaluationResult {
  const TranslationEvaluationResult({
    required this.finalScore,
    required this.deductions,
    required this.suggestedTranslation,
    required this.grammarConcept,
    this.metrics,
  });

  final double finalScore;
  final List<TranslationDeductionResult> deductions;
  final String suggestedTranslation;
  final String grammarConcept;
  final PerformanceMetrics? metrics;

  factory TranslationEvaluationResult.fromJson(Map<String, dynamic> json) {
    final rawDeductions = json['deductions'];
    return TranslationEvaluationResult(
      finalScore: PerformanceMetrics._asDouble(json['final_score']),
      deductions: rawDeductions is List
          ? rawDeductions
              .whereType<Map>()
              .map((item) => TranslationDeductionResult.fromJson(
                  Map<String, dynamic>.from(item)))
              .toList()
          : const [],
      suggestedTranslation: _stringFromAny(
        json['suggested_translation'],
        fallback: 'No suggested translation available.',
      ),
      grammarConcept:
          _stringFromAny(json['grammar_concept'], fallback: 'translation'),
      metrics: PerformanceMetrics.maybeFromResponse(json),
    );
  }
}

class ClozePhraseSet {
  const ClozePhraseSet({
    required this.text,
    required this.phrases,
    required this.correctMapping,
    this.metrics,
  });

  final String text;
  final List<String> phrases;
  final Map<String, String> correctMapping;
  final PerformanceMetrics? metrics;

  factory ClozePhraseSet.fromJson(Map<String, dynamic> json) {
    final rawPhrases = json['phrases'];
    final rawMapping = json['correct_mapping'];
    return ClozePhraseSet(
      text: _stringFromAny(json['text'], fallback: ''),
      phrases: rawPhrases is List
          ? rawPhrases
              .map((phrase) => phrase.toString())
              .where((phrase) => phrase.trim().isNotEmpty)
              .toList()
          : const [],
      correctMapping: rawMapping is Map
          ? Map<String, String>.fromEntries(
              rawMapping.entries.map(
                (entry) =>
                    MapEntry(entry.key.toString(), entry.value.toString()),
              ),
            )
          : const {},
      metrics: PerformanceMetrics.maybeFromResponse(json),
    );
  }
}

class SentenceUpgradePrompt {
  const SentenceUpgradePrompt({
    required this.basicSentence,
    required this.targetStructure,
    required this.instruction,
    this.metrics,
  });

  final String basicSentence;
  final String targetStructure;
  final String instruction;
  final PerformanceMetrics? metrics;

  factory SentenceUpgradePrompt.fromJson(Map<String, dynamic> json) {
    return SentenceUpgradePrompt(
      basicSentence: _stringFromAny(
        json['basic_sentence'],
        fallback: 'The weather was bad. We stayed home.',
      ),
      targetStructure: _stringFromAny(
        json['target_structure'],
        fallback: 'Participle Clause',
      ),
      instruction: _stringFromAny(
        json['instruction'],
        fallback: 'Rewrite the sentence using the target structure.',
      ),
      metrics: PerformanceMetrics.maybeFromResponse(json),
    );
  }
}

class SentenceUpgradeFeedback {
  const SentenceUpgradeFeedback({
    required this.passed,
    required this.feedback,
    required this.suggestedUpgrade,
    required this.detectedStructure,
    this.metrics,
  });

  final bool passed;
  final String feedback;
  final String suggestedUpgrade;
  final String detectedStructure;
  final PerformanceMetrics? metrics;

  factory SentenceUpgradeFeedback.fromJson(Map<String, dynamic> json) {
    return SentenceUpgradeFeedback(
      passed: _boolFromJson(json['passed']),
      feedback:
          _stringFromAny(json['feedback'], fallback: 'Rewrite evaluated.'),
      suggestedUpgrade: _stringFromAny(
        json['suggested_upgrade'],
        fallback: 'No suggestion available.',
      ),
      detectedStructure: _stringFromAny(
        json['detected_structure'],
        fallback: 'unknown',
      ),
      metrics: PerformanceMetrics.maybeFromResponse(json),
    );
  }
}

class StudyMissionTask {
  const StudyMissionTask({
    required this.id,
    required this.taskKey,
    required this.type,
    required this.status,
    required this.priority,
    this.count,
    this.topic,
    this.minutes,
  });

  final int id;
  final String taskKey;
  final String type;
  final String status;
  final String priority;
  final int? count;
  final String? topic;
  final int? minutes;

  factory StudyMissionTask.fromJson(Map<String, dynamic> json) {
    return StudyMissionTask(
      id: PerformanceMetrics._asInt(json['id']),
      taskKey: _stringFromAny(json['task_key'], fallback: 'study_task'),
      type: _stringFromAny(json['type'], fallback: 'study_task'),
      status: _stringFromAny(json['status'], fallback: 'pending'),
      priority: _stringFromAny(json['priority'], fallback: 'core'),
      count: json['count'] == null
          ? null
          : PerformanceMetrics._asInt(json['count']),
      topic: _nullableString(json['topic']),
      minutes: json['minutes'] == null
          ? null
          : PerformanceMetrics._asInt(json['minutes']),
    );
  }
}

class StudyMissionSchedule {
  const StudyMissionSchedule({
    required this.targetExamDate,
    required this.daysRemaining,
    required this.upwardCurve,
    required this.focusSkill,
    required this.tasks,
  });

  final DateTime? targetExamDate;
  final int daysRemaining;
  final double upwardCurve;
  final String focusSkill;
  final List<StudyMissionTask> tasks;

  factory StudyMissionSchedule.fromJson(Map<String, dynamic> json) {
    final rawTasks = json['tasks'];
    return StudyMissionSchedule(
      targetExamDate:
          DateTime.tryParse((json['target_exam_date'] ?? '').toString()),
      daysRemaining: PerformanceMetrics._asInt(json['days_remaining']),
      upwardCurve: PerformanceMetrics._asDouble(json['upward_curve'])
          .clamp(0.0, 1.0)
          .toDouble(),
      focusSkill: _stringFromAny(json['focus_skill'], fallback: 'vocab'),
      tasks: rawTasks is List
          ? rawTasks
              .whereType<Map>()
              .map((item) =>
                  StudyMissionTask.fromJson(Map<String, dynamic>.from(item)))
              .toList()
          : const [],
    );
  }
}

String _stringFromAny(Object? value, {required String fallback}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

class InferenceBadge extends StatelessWidget {
  const InferenceBadge({
    super.key,
    required this.totalTimeSeconds,
    required this.tokensPerSecond,
  });

  final double totalTimeSeconds;
  final double tokensPerSecond;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF101828),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF36F3A5).withOpacity(0.35)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF36F3A5).withOpacity(0.18),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('⚡', style: TextStyle(fontSize: 13)),
          const SizedBox(width: 4),
          Text(
            '${tokensPerSecond.toStringAsFixed(1)} t/s (${totalTimeSeconds.toStringAsFixed(1)}s)',
            style: const TextStyle(
              color: Color(0xFF36F3A5),
              fontWeight: FontWeight.w900,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

Map<String, dynamic> _decodeJsonObject(String body) {
  if (body.trim().isEmpty) return <String, dynamic>{};

  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } on FormatException {
    return <String, dynamic>{};
  }

  return <String, dynamic>{};
}

String _stringValue(
  Map<String, dynamic> data,
  List<String> keys, {
  required String fallback,
}) {
  for (final key in keys) {
    final value = data[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return fallback;
}

String? _activeJwtToken;
String? _activeRefreshToken;
AuthController? _activeAuthController;
ReviewSyncController? _activeReviewSyncController;

class SecureTokenSession {
  const SecureTokenSession({
    required this.accessToken,
    required this.refreshToken,
    this.userId,
    this.email,
    this.displayName,
    this.currentStreak = 0,
    this.hasCompletedOnboarding = false,
    this.isPro = false,
  });

  final String accessToken;
  final String refreshToken;
  final int? userId;
  final String? email;
  final String? displayName;
  final int currentStreak;
  final bool hasCompletedOnboarding;
  final bool isPro;
}

class SecureTokenStorage {
  static const String _accessTokenKey = 'auth_access_token_v1';
  static const String _refreshTokenKey = 'auth_refresh_token_v1';
  static const String _profileKey = 'auth_profile_v1';
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<void> writeSession({
    required String accessToken,
    required String refreshToken,
    required int userId,
    required String email,
    String? displayName,
    required int currentStreak,
    required bool hasCompletedOnboarding,
    required bool isPro,
  }) async {
    await Future.wait([
      _storage.write(key: _accessTokenKey, value: accessToken),
      _storage.write(key: _refreshTokenKey, value: refreshToken),
      _storage.write(
        key: _profileKey,
        value: jsonEncode({
          'user_id': userId,
          'email': email,
          'display_name': displayName,
          'current_streak': currentStreak,
          'has_completed_onboarding': hasCompletedOnboarding,
          'is_pro': isPro,
        }),
      ),
    ]);
  }

  Future<SecureTokenSession?> readSession() async {
    final values = await Future.wait([
      _storage.read(key: _accessTokenKey),
      _storage.read(key: _refreshTokenKey),
      _storage.read(key: _profileKey),
    ]);
    final accessToken = values[0];
    final refreshToken = values[1];
    if (accessToken == null || refreshToken == null) return null;
    final profile = _decodeJsonObject(values[2] ?? '');
    final userId = PerformanceMetrics._asInt(profile['user_id']);
    return SecureTokenSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      userId: userId > 0 ? userId : null,
      email: _nullableString(profile['email']),
      displayName: _nullableString(profile['display_name']),
      currentStreak: PerformanceMetrics._asInt(profile['current_streak']),
      hasCompletedOnboarding:
          _boolFromJson(profile['has_completed_onboarding']),
      isPro: _boolFromJson(profile['is_pro']),
    );
  }

  Future<void> deleteSession() async {
    await Future.wait([
      _storage.delete(key: _accessTokenKey),
      _storage.delete(key: _refreshTokenKey),
      _storage.delete(key: _profileKey),
    ]);
  }
}

class AuthRequiredException implements Exception {
  const AuthRequiredException();
}

Map<String, String> _authHeaders({bool jsonContent = false}) {
  final token = _activeJwtToken;
  if (token == null || token.isEmpty) {
    throw const AuthRequiredException();
  }
  return {
    'Authorization': 'Bearer $token',
    if (jsonContent) 'Content-Type': 'application/json',
  };
}

Future<http.Response> _authenticatedGet(Uri uri) async {
  var response = await http.get(uri, headers: _authHeaders());
  if (response.statusCode == 401 &&
      await (_activeAuthController?.refreshAccessToken() ??
          Future.value(false))) {
    response = await http.get(uri, headers: _authHeaders());
  }
  return response;
}

Future<http.Response> _authenticatedPost(
  Uri uri, {
  Object? body,
  bool jsonContent = true,
}) async {
  final requestBody = jsonContent ? _bodyWithAppMode(body) : body;
  var response = await http.post(
    uri,
    headers: _authHeaders(jsonContent: jsonContent),
    body: requestBody,
  );
  if (response.statusCode == 401 &&
      await (_activeAuthController?.refreshAccessToken() ??
          Future.value(false))) {
    response = await http.post(
      uri,
      headers: _authHeaders(jsonContent: jsonContent),
      body: requestBody,
    );
  }
  return response;
}

Future<http.Response> _authenticatedPatch(Uri uri, {Object? body}) async {
  final requestBody = _bodyWithAppMode(body);
  var response = await http.patch(
    uri,
    headers: _authHeaders(jsonContent: true),
    body: requestBody,
  );
  if (response.statusCode == 401 &&
      await (_activeAuthController?.refreshAccessToken() ??
          Future.value(false))) {
    response = await http.patch(
      uri,
      headers: _authHeaders(jsonContent: true),
      body: requestBody,
    );
  }
  return response;
}

Future<http.Response> _authenticatedDelete(Uri uri) async {
  var response = await http.delete(uri, headers: _authHeaders());
  if (response.statusCode == 401 &&
      await (_activeAuthController?.refreshAccessToken() ??
          Future.value(false))) {
    response = await http.delete(uri, headers: _authHeaders());
  }
  return response;
}

http.MultipartRequest _authenticatedMultipartRequest(String method, Uri uri) {
  return http.MultipartRequest(method, uri)
    ..headers.addAll(_authHeaders())
    ..fields['app_mode'] = _currentAppModeApiValue;
}

Object? _bodyWithAppMode(Object? body) {
  final appMode = _currentAppModeApiValue;
  if (body == null) {
    return jsonEncode({'app_mode': appMode});
  }
  if (body is Map<String, dynamic>) {
    return jsonEncode({...body, 'app_mode': body['app_mode'] ?? appMode});
  }
  if (body is Map) {
    final data = <String, dynamic>{};
    for (final entry in body.entries) {
      data[entry.key.toString()] = entry.value;
    }
    data['app_mode'] = data['app_mode'] ?? appMode;
    return jsonEncode(data);
  }
  if (body is String) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final data = <String, dynamic>{};
        for (final entry in decoded.entries) {
          data[entry.key.toString()] = entry.value;
        }
        data['app_mode'] = data['app_mode'] ?? appMode;
        return jsonEncode(data);
      }
    } catch (_) {
      return body;
    }
  }
  return body;
}

class AiQuotaExceededException implements Exception {
  const AiQuotaExceededException();
}

class AppModeController extends ChangeNotifier {
  AppMode _mode = AppMode.engagement;

  AppMode get mode => _mode;
  bool get isFocus => _mode == AppMode.focus;
  String get apiValue => _appModeApiValue(_mode);

  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(kAppModeKey);
      _mode = saved == 'focus' ? AppMode.focus : AppMode.engagement;
      _applySideEffects();
      notifyListeners();
    } catch (_) {
      _applySideEffects();
    }
  }

  Future<void> setMode(AppMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    _applySideEffects();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kAppModeKey, apiValue);
    } catch (_) {
      // App mode should still work even if persistence fails.
    }
  }

  Future<void> toggle() {
    return setMode(_mode == AppMode.focus ? AppMode.engagement : AppMode.focus);
  }

  void _applySideEffects() {
    _currentAppModeApiValue = apiValue;
    HapticFeedback.enabled = _mode == AppMode.engagement;
  }
}

class RewardVFXController extends ChangeNotifier {
  int _burstId = 0;
  String _reason = '';

  int get burstId => _burstId;
  String get reason => _reason;

  void trigger(String reason) {
    _reason = reason;
    _burstId += 1;
    notifyListeners();
  }
}

bool _isAiQuotaLimitResponse(http.Response response) {
  if (response.statusCode != 403) return false;
  final data = _decodeJsonObject(response.body);
  final detail = (data['detail'] ?? data['message'] ?? data['error'] ?? '')
      .toString()
      .toLowerCase();
  return detail.contains('daily ai generation limit reached') ||
      detail.contains('ai generation limit');
}

void _throwIfAiQuotaExceeded(http.Response response) {
  if (_isAiQuotaLimitResponse(response)) {
    throw const AiQuotaExceededException();
  }
}

Future<void> _showAiQuotaBottomSheet(BuildContext context) async {
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      final router = GoRouter.of(context);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: CleanCard(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 62,
                    height: 62,
                    decoration: BoxDecoration(
                      color: kNeonGreen.withOpacity(0.12),
                      shape: BoxShape.circle,
                      border: Border.all(color: kNeonGreen.withOpacity(0.42)),
                      boxShadow: [
                        BoxShadow(
                          color: kNeonGreen.withOpacity(0.16),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text('⚡', style: TextStyle(fontSize: 30)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'AI Energy Empty',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '⚡ You\'ve used all your AI energy for today! Come back tomorrow to generate more, or review your Error Ledger.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: kTextSecondary,
                          height: 1.45,
                        ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(context).pop();
                            router.push('/error-ledger');
                          },
                          icon: const Icon(Icons.fact_check_outlined),
                          label: const Text('Error Ledger'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () {
                            Navigator.of(context).pop();
                            router.push('/paywall');
                          },
                          icon: const Icon(Icons.workspace_premium_rounded),
                          label: const Text('Go Pro'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class ShareCaptureService {
  const ShareCaptureService._();

  static Future<void> shareBoundary({
    required BuildContext context,
    required GlobalKey boundaryKey,
    required String fileName,
    required String shareText,
  }) async {
    try {
      await WidgetsBinding.instance.endOfFrame;
      final boundary = boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        throw StateError('Share boundary is not ready.');
      }

      final image = await boundary.toImage(pixelRatio: 3);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData?.buffer.asUint8List();
      if (bytes == null || bytes.isEmpty) {
        throw StateError('Unable to render share image.');
      }

      await Share.shareXFiles(
        [
          XFile.fromData(
            bytes,
            mimeType: 'image/png',
            name: fileName,
          ),
        ],
        text: shareText,
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Could not prepare the share image yet. Try again.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }
}

class ShareWatermark extends StatelessWidget {
  const ShareWatermark({super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      'Generated by GSAT_Max',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: kTextTertiary,
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
    );
  }
}

class ReviewSyncAction {
  const ReviewSyncAction({
    required this.actionId,
    required this.userId,
    required this.vocabId,
    required this.quality,
    required this.createdAt,
  });

  final String actionId;
  final int userId;
  final int vocabId;
  final int quality;
  final DateTime createdAt;

  Map<String, dynamic> toJson() {
    return {
      'action_id': actionId,
      'user_id': userId,
      'vocab_id': vocabId,
      'quality': quality,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory ReviewSyncAction.fromJson(Map<String, dynamic> json) {
    return ReviewSyncAction(
      actionId: _stringFromAny(json['action_id'], fallback: ''),
      userId: PerformanceMetrics._asInt(json['user_id']),
      vocabId: PerformanceMetrics._asInt(json['vocab_id']),
      quality: PerformanceMetrics._asInt(json['quality']),
      createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()) ??
          DateTime.now(),
    );
  }
}

class ReviewSyncController extends ChangeNotifier {
  static const String _queueKey = 'review_sync_queue_v1';
  static final Uri _updateProgressEndpoint =
      AppConfig.apiUri('/vocab/update_progress');

  SharedPreferences? _prefs;
  List<ReviewSyncAction> _pendingActions = <ReviewSyncAction>[];
  Timer? _retryTimer;
  bool _isSyncing = false;

  ReviewSyncController() {
    _activeReviewSyncController = this;
  }

  bool get isSyncing => _isSyncing;
  bool get hasPendingActions => _pendingActions.isNotEmpty;
  int get pendingCount => _pendingActions.length;

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    _pendingActions = _readQueue();
    _retryTimer ??= Timer.periodic(
      const Duration(minutes: 2),
      (_) => unawaited(syncNow()),
    );
    notifyListeners();
    unawaited(syncNow());
  }

  Future<void> enqueueReview({
    required int vocabId,
    required int quality,
  }) async {
    final userId = _activeAuthController?.userId;
    if (userId == null || userId <= 0) {
      throw StateError(
          'A signed-in user is required to queue review progress.');
    }
    final actionId = [
      userId,
      DateTime.now().microsecondsSinceEpoch,
      math.Random.secure().nextInt(1 << 32),
    ].join('-');
    _pendingActions = [
      ..._pendingActions,
      ReviewSyncAction(
        actionId: actionId,
        userId: userId,
        vocabId: vocabId,
        quality: quality,
        createdAt: DateTime.now(),
      ),
    ];
    await _persistQueue();
    notifyListeners();
    unawaited(syncNow());
  }

  Future<void> syncNow() async {
    final currentUserId = _activeAuthController?.userId;
    if (_isSyncing || _pendingActions.isEmpty || currentUserId == null) return;
    _isSyncing = true;
    notifyListeners();

    final snapshot = List<ReviewSyncAction>.from(_pendingActions);
    final snapshotIds = snapshot.map((action) => action.actionId).toSet();
    final remaining = <ReviewSyncAction>[];
    for (final action in snapshot) {
      if (action.userId != currentUserId) {
        remaining.add(action);
        continue;
      }
      try {
        final response = await _authenticatedPost(
          _updateProgressEndpoint,
          body: jsonEncode({
            'vocab_id': action.vocabId,
            'quality': action.quality,
            'action_id': action.actionId,
          }),
        ).timeout(const Duration(seconds: 8));

        if (response.statusCode >= 500 ||
            response.statusCode == 401 ||
            response.statusCode == 429) {
          remaining.add(action);
        }
      } catch (_) {
        remaining.add(action);
      }
    }

    final actionsQueuedDuringSync = _pendingActions
        .where((action) => !snapshotIds.contains(action.actionId))
        .toList();
    _pendingActions = [...remaining, ...actionsQueuedDuringSync];
    try {
      await _persistQueue();
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  void onAuthenticatedUser(int userId) {
    if (userId > 0) unawaited(syncNow());
  }

  Future<void> discardUser(int userId) async {
    _pendingActions =
        _pendingActions.where((action) => action.userId != userId).toList();
    await _persistQueue();
    notifyListeners();
  }

  List<ReviewSyncAction> _readQueue() {
    final raw = _prefs?.getString(_queueKey);
    if (raw == null || raw.trim().isEmpty) return <ReviewSyncAction>[];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <ReviewSyncAction>[];
      return decoded
          .whereType<Map>()
          .map((item) =>
              ReviewSyncAction.fromJson(Map<String, dynamic>.from(item)))
          .where(
            (action) =>
                action.actionId.isNotEmpty &&
                action.userId > 0 &&
                action.vocabId > 0 &&
                action.quality > 0,
          )
          .toList();
    } catch (_) {
      return <ReviewSyncAction>[];
    }
  }

  Future<void> _persistQueue() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(
      _queueKey,
      jsonEncode(_pendingActions.map((action) => action.toJson()).toList()),
    );
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }
}

class AuthController extends ChangeNotifier {
  static final Uri _loginEndpoint = AppConfig.apiUri('/auth/login');
  static final Uri _registerEndpoint = AppConfig.apiUri('/auth/register');
  static final Uri _refreshEndpoint = AppConfig.apiUri('/auth/refresh');
  static final Uri _logoutEndpoint = AppConfig.apiUri('/auth/logout');
  static final Uri _entitlementEndpoint = AppConfig.apiUri('/user/entitlement');
  static final Uri _deleteAccountEndpoint = AppConfig.apiUri('/user/account');
  AuthController({
    http.Client? client,
    SecureTokenStorage? secureStorage,
    bool enablePostAuthSideEffects = true,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _secureStorage = secureStorage ?? SecureTokenStorage(),
        _enablePostAuthSideEffects = enablePostAuthSideEffects {
    _activeAuthController = this;
    unawaited(restoreSession());
  }

  final http.Client _client;
  final bool _ownsClient;
  final SecureTokenStorage _secureStorage;
  final bool _enablePostAuthSideEffects;

  bool _isInitializing = true;
  bool _isLoggedIn = false;
  bool _isBusy = false;
  String? _errorMessage;
  String? _token;
  int? _userId;
  String? _email;
  String? _displayName;
  int _currentStreak = 0;
  bool _hasCompletedOnboarding = false;
  bool _isPro = false;
  Future<bool>? _refreshInFlight;

  bool get isInitializing => _isInitializing;
  bool get isLoggedIn => _isLoggedIn;
  bool get isBusy => _isBusy;
  String? get errorMessage => _errorMessage;
  String? get token => _token;
  int? get userId => _userId;
  String? get email => _email;
  String? get displayName => _displayName;
  int get currentStreak => _currentStreak;
  bool get hasCompletedOnboarding => _hasCompletedOnboarding;
  bool get isPro => _isPro;

  Future<bool> login({
    required String email,
    required String password,
  }) {
    return _authenticate(
      endpoint: _loginEndpoint,
      payload: {'email': email, 'password': password},
    );
  }

  Future<bool> register({
    required String email,
    required String password,
    String? displayName,
  }) {
    return _authenticate(
      endpoint: _registerEndpoint,
      payload: {
        'email': email,
        'password': password,
        if (displayName != null && displayName.trim().isNotEmpty)
          'display_name': displayName.trim(),
      },
    );
  }

  Future<bool> _authenticate({
    required Uri endpoint,
    required Map<String, dynamic> payload,
  }) async {
    _isBusy = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _client
          .post(
            endpoint,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 12));
      final data = _decodeJsonObject(response.body);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _applyAuthenticatedResponse(data);
        if (_enablePostAuthSideEffects && endpoint == _registerEndpoint) {
          unawaited(
            _authenticatedPost(
              AppConfig.apiUri('/auth/email-verification/request'),
              body: '{}',
            ).catchError((Object _) => http.Response('', 503)),
          );
        }
        if (_enablePostAuthSideEffects) {
          unawaited(_configurePostAuthNotifications());
        }
        return true;
      }

      _errorMessage = _stringValue(
        data,
        ['detail', 'message', 'error'],
        fallback: 'Authentication failed with status ${response.statusCode}.',
      );
      return false;
    } on TimeoutException {
      _errorMessage = 'Authentication timed out. Please try again.';
      return false;
    } on SocketException {
      _errorMessage =
          'Cannot reach the auth server. Make sure FastAPI is running.';
      return false;
    } catch (_) {
      _errorMessage = 'Unable to authenticate right now.';
      return false;
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  Future<void> _configurePostAuthNotifications() async {
    try {
      await NotificationService.instance.requestPermissionsGracefully();
      await NotificationService.instance.scheduleDailyReviewReminder();
    } catch (error, stack) {
      await TelemetryService.instance.recordError(
        error,
        stack,
        source: 'post_auth_notifications',
      );
    }
  }

  Future<void> restoreSession() async {
    try {
      final session = await _secureStorage.readSession();
      if (session == null) return;
      _token = session.accessToken;
      _activeJwtToken = session.accessToken;
      _activeRefreshToken = session.refreshToken;
      if (session.userId != null && session.email != null) {
        _userId = session.userId;
        _email = session.email;
        _displayName = session.displayName;
        _currentStreak = session.currentStreak;
        _hasCompletedOnboarding = session.hasCompletedOnboarding;
        _isPro = session.isPro;
        _isLoggedIn = true;
      }
      await refreshAccessToken(clearOnFailure: true);
    } catch (_) {
      await _clearLocalSession();
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  Future<bool> refreshAccessToken({bool clearOnFailure = true}) {
    final active = _refreshInFlight;
    if (active != null) return active;
    final operation = _performRefresh(clearOnFailure: clearOnFailure);
    _refreshInFlight = operation;
    operation.whenComplete(() => _refreshInFlight = null);
    return operation;
  }

  Future<bool> _performRefresh({required bool clearOnFailure}) async {
    final refreshToken = _activeRefreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return false;
    var tokenWasRejected = false;
    try {
      final response = await _client
          .post(
            _refreshEndpoint,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': refreshToken}),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _applyAuthenticatedResponse(_decodeJsonObject(response.body));
        return true;
      }
      tokenWasRejected = response.statusCode == 400 ||
          response.statusCode == 401 ||
          response.statusCode == 403;
    } catch (_) {
      // Keep the cached profile signed in while offline or during server outages.
    }
    if (clearOnFailure && tokenWasRejected) {
      await _clearLocalSession();
      notifyListeners();
    }
    return false;
  }

  Future<void> _applyAuthenticatedResponse(Map<String, dynamic> data) async {
    final accessToken = _stringValue(data, ['access_token'], fallback: '');
    final refreshToken = _stringValue(data, ['refresh_token'], fallback: '');
    if (accessToken.isEmpty || refreshToken.isEmpty) {
      throw const FormatException('Authentication tokens are missing.');
    }
    _token = accessToken;
    _activeJwtToken = accessToken;
    _activeRefreshToken = refreshToken;
    _userId = PerformanceMetrics._asInt(data['user_id']);
    _email = _stringValue(data, ['email'], fallback: _email ?? '');
    _displayName = _nullableString(data['display_name']);
    _currentStreak = PerformanceMetrics._asInt(data['current_streak']);
    _hasCompletedOnboarding = _boolFromJson(data['has_completed_onboarding']);
    _isPro = _boolFromJson(data['is_pro']);
    _isLoggedIn = true;
    await _secureStorage.writeSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      userId: _userId!,
      email: _email ?? '',
      displayName: _displayName,
      currentStreak: _currentStreak,
      hasCompletedOnboarding: _hasCompletedOnboarding,
      isPro: _isPro,
    );
    _activeReviewSyncController?.onAuthenticatedUser(_userId!);
  }

  Future<bool> completeOnboarding(List<Map<String, dynamic>> answers) async {
    _isBusy = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _authenticatedPost(
        AppConfig.apiUri('/user/initialize'),
        body: jsonEncode({'answers': answers}),
      ).timeout(const Duration(seconds: 15));
      final data = _decodeJsonObject(response.body);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _hasCompletedOnboarding = _boolFromJson(
          data['has_completed_onboarding'],
        );
        return _hasCompletedOnboarding;
      }

      _errorMessage = _stringValue(
        data,
        ['detail', 'message', 'error'],
        fallback: 'Could not generate your starter profile yet.',
      );
      return false;
    } on TimeoutException {
      _errorMessage = 'Profile generation timed out. Please try again.';
      return false;
    } on SocketException {
      _errorMessage =
          'Cannot reach the profile generator. Make sure FastAPI is running.';
      return false;
    } catch (_) {
      _errorMessage = 'Unable to generate your profile right now.';
      return false;
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  void markOnboardingCompleted() {
    _hasCompletedOnboarding = true;
    unawaited(_persistCurrentSession());
    unawaited(NotificationService.instance.scheduleDailyReviewReminder());
    notifyListeners();
  }

  Future<bool> syncEntitlement() async {
    _isBusy = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _authenticatedGet(_entitlementEndpoint)
          .timeout(const Duration(seconds: 12));
      final data = _decodeJsonObject(response.body);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _isPro = _boolFromJson(data['is_pro']);
        await _persistCurrentSession();
        return _isPro;
      }

      _errorMessage = _stringValue(
        data,
        ['detail', 'message', 'error'],
        fallback: 'Could not activate Pro (${response.statusCode}).',
      );
      return false;
    } on TimeoutException {
      _errorMessage = 'Upgrade timed out. Please try again.';
      return false;
    } on SocketException {
      _errorMessage =
          'Cannot reach the upgrade server. Make sure FastAPI is running.';
      return false;
    } catch (_) {
      _errorMessage = 'Unable to activate Pro right now.';
      return false;
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  Future<bool> deleteAccount() async {
    _isBusy = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _authenticatedDelete(_deleteAccountEndpoint)
          .timeout(const Duration(seconds: 12));
      final data = _decodeJsonObject(response.body);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final deletedUserId = _userId;
        if (deletedUserId != null) {
          await _activeReviewSyncController?.discardUser(deletedUserId);
        }
        await _clearLocalSession();
        return true;
      }

      _errorMessage = _stringValue(
        data,
        ['detail', 'message', 'error'],
        fallback: 'Could not delete account (${response.statusCode}).',
      );
      return false;
    } on TimeoutException {
      _errorMessage = 'Account deletion timed out. Please try again.';
      return false;
    } on SocketException {
      _errorMessage =
          'Cannot reach the account server. Make sure FastAPI is running.';
      return false;
    } catch (_) {
      _errorMessage = 'Unable to delete account right now.';
      return false;
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    final refreshToken = _activeRefreshToken;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        await _client
            .post(
              _logoutEndpoint,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'refresh_token': refreshToken}),
            )
            .timeout(const Duration(seconds: 6));
      } catch (_) {
        // Local logout must still complete while offline.
      }
    }
    await _clearLocalSession();
    notifyListeners();
  }

  Future<void> _clearLocalSession() async {
    await _secureStorage.deleteSession();
    _token = null;
    _activeJwtToken = null;
    _activeRefreshToken = null;
    _userId = null;
    _email = null;
    _displayName = null;
    _currentStreak = 0;
    _hasCompletedOnboarding = false;
    _isPro = false;
    _isLoggedIn = false;
  }

  Future<void> _persistCurrentSession() async {
    final accessToken = _activeJwtToken;
    final refreshToken = _activeRefreshToken;
    final userId = _userId;
    if (accessToken == null ||
        refreshToken == null ||
        userId == null ||
        (_email ?? '').isEmpty) {
      return;
    }
    await _secureStorage.writeSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      userId: userId,
      email: _email!,
      displayName: _displayName,
      currentStreak: _currentStreak,
      hasCompletedOnboarding: _hasCompletedOnboarding,
      isPro: _isPro,
    );
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }
}

class AppRestartScope extends StatefulWidget {
  const AppRestartScope({
    required this.child,
    super.key,
  });

  final Widget child;

  static void restartApp(BuildContext context) {
    context.findAncestorStateOfType<_AppRestartScopeState>()?.restart();
  }

  @override
  State<AppRestartScope> createState() => _AppRestartScopeState();
}

class _AppRestartScopeState extends State<AppRestartScope> {
  Key _restartKey = UniqueKey();

  void restart() {
    setState(() {
      _restartKey = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _restartKey,
      child: widget.child,
    );
  }
}

class SystemAnomalyFallback extends StatelessWidget {
  const SystemAnomalyFallback({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: kAppBackground,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: kSurfaceGlassStrong,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: kDangerRed.withOpacity(0.4)),
                boxShadow: [
                  BoxShadow(
                    color: kDangerRed.withOpacity(0.18),
                    blurRadius: 28,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: kDangerRed.withOpacity(0.12),
                      border: Border.all(color: kDangerRed.withOpacity(0.5)),
                    ),
                    child: const Icon(
                      Icons.warning_amber_rounded,
                      color: kDangerRed,
                      size: 34,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'System Anomaly Detected',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: kTextPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'The app captured the crash details locally. Restart the interface to continue learning.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: kTextSecondary,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: () => AppRestartScope.restartApp(context),
                    icon: const Icon(Icons.restart_alt_rounded),
                    label: const Text('Restart App'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GsatEnglishApp extends ConsumerStatefulWidget {
  const GsatEnglishApp({super.key});

  @override
  ConsumerState<GsatEnglishApp> createState() => _GsatEnglishAppState();
}

class _GsatEnglishAppState extends ConsumerState<GsatEnglishApp> {
  bool _nativeSplashRemoved = false;

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    final auth = ref.watch(authControllerProvider);
    if (!auth.isInitializing && !_nativeSplashRemoved) {
      _nativeSplashRemoved = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          FlutterNativeSplash.remove();
        } catch (_) {
          // A missing native splash channel must not block the first frame.
        }
      });
    }
    final appMode = ref.watch(appModeControllerProvider).mode;
    final isFocusMode = appMode == AppMode.focus;
    final primaryColor = isFocusMode ? Colors.white : kNeonGreen;
    final secondaryColor =
        isFocusMode ? const Color(0xFFD4D4D4) : kElectricBlue;
    final scaffoldColor = isFocusMode ? Colors.black : kAppBackground;
    final surfaceColor =
        isFocusMode ? const Color(0xFF181818) : kSurfaceGlassStrong;

    return MaterialApp.router(
      title: 'GSAT_Max',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
      builder: (context, child) {
        final app = child ?? const SizedBox.shrink();
        final layeredApp = _RewardVFXOverlay(child: app);
        if (!isFocusMode) return layeredApp;
        return ColorFiltered(
          colorFilter: const ColorFilter.matrix(<double>[
            0.2126,
            0.7152,
            0.0722,
            0,
            0,
            0.2126,
            0.7152,
            0.0722,
            0,
            0,
            0.2126,
            0.7152,
            0.0722,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
          ]),
          child: layeredApp,
        );
      },
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryColor,
          brightness: Brightness.dark,
        ).copyWith(
          primary: primaryColor,
          secondary: secondaryColor,
          surface: surfaceColor,
          background: scaffoldColor,
        ),
        scaffoldBackgroundColor: scaffoldColor,
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            color: kTextPrimary,
            fontWeight: FontWeight.w900,
          ),
          headlineSmall: TextStyle(
            color: kTextPrimary,
            fontWeight: FontWeight.w900,
          ),
          titleLarge: TextStyle(
            color: kTextPrimary,
            fontWeight: FontWeight.w900,
          ),
          titleMedium: TextStyle(
            color: kTextPrimary,
            fontWeight: FontWeight.w800,
          ),
          bodyLarge: TextStyle(color: kTextSecondary),
          bodyMedium: TextStyle(color: kTextSecondary),
          bodySmall: TextStyle(color: kTextTertiary),
          labelLarge: TextStyle(
            color: kTextSecondary,
            fontWeight: FontWeight.w700,
          ),
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
          backgroundColor: Colors.transparent,
          foregroundColor: kTextPrimary,
          surfaceTintColor: Colors.transparent,
        ),
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          backgroundColor: isFocusMode ? Colors.black : const Color(0xF0121212),
          selectedItemColor: primaryColor,
          unselectedItemColor: kTextTertiary,
          type: BottomNavigationBarType.fixed,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: primaryColor,
            foregroundColor:
                isFocusMode ? Colors.black : const Color(0xFF07120D),
            minimumSize: const Size.fromHeight(52),
            textStyle: const TextStyle(fontWeight: FontWeight.w900),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: primaryColor,
            side: BorderSide(
                color: isFocusMode ? Colors.white70 : const Color(0x6636F3A5)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: primaryColor),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: primaryColor,
          foregroundColor: isFocusMode ? Colors.black : const Color(0xFF07120D),
        ),
        chipTheme: ChipThemeData(
          backgroundColor:
              isFocusMode ? const Color(0xFF202020) : const Color(0x661B2430),
          selectedColor: primaryColor.withOpacity(0.18),
          disabledColor: const Color(0x331B2430),
          side: BorderSide(color: isFocusMode ? Colors.white24 : kGlassBorder),
          labelStyle: const TextStyle(
            color: kTextSecondary,
            fontWeight: FontWeight.w700,
          ),
          secondaryLabelStyle: const TextStyle(color: kTextPrimary),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: const Color(0xEE1B2430),
          contentTextStyle: const TextStyle(
            color: kTextPrimary,
            fontWeight: FontWeight.w700,
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor:
              isFocusMode ? const Color(0xFF181818) : const Color(0x991B2430),
          labelStyle: const TextStyle(color: kTextSecondary),
          hintStyle: const TextStyle(color: kTextTertiary),
          prefixIconColor: kTextTertiary,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide:
                BorderSide(color: isFocusMode ? Colors.white24 : kGlassBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide:
                BorderSide(color: isFocusMode ? Colors.white24 : kGlassBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: primaryColor, width: 2),
          ),
        ),
      ),
    );
  }
}

class _RewardVFXOverlay extends ConsumerStatefulWidget {
  const _RewardVFXOverlay({required this.child});

  final Widget child;

  @override
  ConsumerState<_RewardVFXOverlay> createState() => _RewardVFXOverlayState();
}

class _RewardVFXOverlayState extends ConsumerState<_RewardVFXOverlay> {
  static const String _sevenDayRewardKey = 'reward_seen_7_day_streak_v1';

  late final ConfettiController _confettiController;
  int _lastBurstId = 0;
  bool _hasCheckedStreakReward = false;

  @override
  void initState() {
    super.initState();
    _confettiController = ConfettiController(
      duration: const Duration(milliseconds: 1800),
    );
  }

  @override
  void dispose() {
    _confettiController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<RewardVFXController>(rewardVFXControllerProvider,
        (previous, next) {
      if (next.burstId != _lastBurstId) {
        _lastBurstId = next.burstId;
        _fireReward();
      }
    });

    final streak = ref.watch(authControllerProvider).currentStreak;
    if (!_hasCheckedStreakReward && streak >= 7) {
      _hasCheckedStreakReward = true;
      unawaited(_maybeTriggerSevenDayStreakReward());
    }

    return Stack(
      children: [
        widget.child,
        IgnorePointer(
          child: Align(
            alignment: Alignment.center,
            child: ConfettiWidget(
              confettiController: _confettiController,
              blastDirectionality: BlastDirectionality.explosive,
              emissionFrequency: 0.08,
              numberOfParticles: 58,
              maxBlastForce: 42,
              minBlastForce: 12,
              gravity: 0.18,
              shouldLoop: false,
              colors: const [
                kNeonGreen,
                kElectricBlue,
                Colors.white,
                Color(0xFF7CFFCB),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _maybeTriggerSevenDayStreakReward() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_sevenDayRewardKey) ?? false) return;
    await prefs.setBool(_sevenDayRewardKey, true);
    if (!mounted) return;
    ref.read(rewardVFXControllerProvider).trigger('7-day streak');
  }

  void _fireReward() {
    if (ref.read(appModeControllerProvider).isFocus) return;
    _confettiController.play();
    unawaited(_rewardHapticSequence());
  }

  Future<void> _rewardHapticSequence() async {
    await HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    await HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 110));
    await HapticFeedback.mediumImpact();
  }
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _displayNameController = TextEditingController();
  bool _isRegisterMode = false;
  bool _acceptedLegalTerms = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);

    if (auth.isInitializing) {
      return const Scaffold(body: Center(child: GrammarSkeleton()));
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2F80ED),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.school_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'GSAT_Max',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '為台灣高中生打造的學測英文訓練：單字、閱讀、文法與寫作，一站完成。',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: kTextTertiary,
                          height: 1.45,
                        ),
                  ),
                  const SizedBox(height: 32),
                  if (_isRegisterMode) ...[
                    TextField(
                      controller: _displayNameController,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: '顯示名稱',
                        prefixIcon: Icon(Icons.badge_outlined),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: '電子郵件',
                      prefixIcon: Icon(Icons.mail_outline_rounded),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    onSubmitted: (_) => _submit(auth),
                    decoration: InputDecoration(
                      labelText: '密碼',
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      helperText: _isRegisterMode ? '請使用至少 8 個字元。' : null,
                    ),
                  ),
                  if (_isRegisterMode) ...[
                    const SizedBox(height: 14),
                    Container(
                      decoration: BoxDecoration(
                        color: kSurfaceGlass,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: kGlassBorder),
                      ),
                      child: Column(
                        children: [
                          CheckboxListTile(
                            value: _acceptedLegalTerms,
                            onChanged: auth.isBusy
                                ? null
                                : (value) {
                                    setState(() {
                                      _acceptedLegalTerms = value ?? false;
                                    });
                                  },
                            activeColor: kNeonGreen,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: const Text(
                              '我同意服務條款，並了解 AI 產生的評量可能包含錯誤。',
                              style: TextStyle(height: 1.35),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () => context.push('/legal'),
                                icon: const Icon(Icons.gavel_outlined),
                                label: const Text('查看服務條款與隱私權政策'),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (auth.errorMessage != null) ...[
                    const SizedBox(height: 14),
                    _StatusBanner(
                      message: auth.errorMessage!,
                      icon: Icons.error_outline_rounded,
                      color: kDangerRed,
                      backgroundColor: kDangerRed,
                    ),
                  ],
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    onPressed: auth.isBusy ? null : () => _submit(auth),
                    icon: auth.isBusy
                        ? const Icon(Icons.hourglass_top_rounded)
                        : const Icon(Icons.arrow_forward_rounded),
                    label: Text(
                      auth.isBusy
                          ? '連線中...'
                          : _isRegisterMode
                              ? '建立帳號'
                              : '開始練習',
                    ),
                  ),
                  if (!_isRegisterMode) ...[
                    const SizedBox(height: 10),
                    Center(
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed:
                                auth.isBusy ? null : _requestPasswordReset,
                            child: const Text('忘記密碼？'),
                          ),
                          TextButton(
                            onPressed: () => context.push('/legal'),
                            child: const Text('條款與隱私權'),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Center(
                    child: TextButton(
                      onPressed: auth.isBusy
                          ? null
                          : () {
                              setState(() {
                                _isRegisterMode = !_isRegisterMode;
                                if (!_isRegisterMode) {
                                  _acceptedLegalTerms = false;
                                }
                              });
                            },
                      child: Text(
                        _isRegisterMode ? '我已經有帳號' : '建立新帳號',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit(AuthController auth) async {
    FocusScope.of(context).unfocus();
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (_isRegisterMode) {
      if (!_acceptedLegalTerms) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                '建立帳號前，請先同意服務條款。',
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
        return;
      }
      await auth.register(
        email: email,
        password: password,
        displayName: _displayNameController.text,
      );
    } else {
      await auth.login(email: email, password: password);
    }
  }

  Future<void> _requestPasswordReset() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter your email address first.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    try {
      final response = await http
          .post(
            AppConfig.apiUri('/auth/password-reset/request'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email}),
          )
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'If that account exists, password reset instructions were sent.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        throw StateError('Reset request failed.');
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Could not request a password reset. Try again shortly.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

class PasswordResetScreen extends StatefulWidget {
  const PasswordResetScreen({super.key, required this.token});

  final String token;

  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  bool _isSubmitting = false;
  bool _isComplete = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reset Password')),
      body: AppPage(
        children: [
          const PageIntro(
            icon: Icons.password_rounded,
            title: 'Choose a new password',
            subtitle:
                'Use at least eight characters and keep it unique to GSAT_Max.',
          ),
          const SizedBox(height: 18),
          if (_isComplete)
            CleanCard(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Icon(Icons.check_circle_rounded,
                        color: kNeonGreen, size: 52),
                    const SizedBox(height: 12),
                    Text('Password updated',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    const Text(
                      'All existing refresh sessions were revoked. Sign in again with your new password.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: kTextSecondary, height: 1.4),
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: () => context.go('/login'),
                      icon: const Icon(Icons.login_rounded),
                      label: const Text('Return to Login'),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New password',
                prefixIcon: Icon(Icons.lock_outline_rounded),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _confirmationController,
              obscureText: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Confirm new password',
                prefixIcon: Icon(Icons.lock_reset_rounded),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              _StatusBanner(
                message: _error!,
                icon: Icons.error_outline_rounded,
                color: kDangerRed,
                backgroundColor: kDangerRed,
              ),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _isSubmitting ? null : _submit,
              icon: Icon(
                _isSubmitting
                    ? Icons.hourglass_top_rounded
                    : Icons.password_rounded,
              ),
              label: Text(_isSubmitting ? 'Updating...' : 'Update Password'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final password = _passwordController.text;
    if (widget.token.length < 32) {
      setState(() => _error = 'This reset link is incomplete or invalid.');
      return;
    }
    if (password.length < 8) {
      setState(() => _error = 'Use at least eight characters.');
      return;
    }
    if (password != _confirmationController.text) {
      setState(() => _error = 'The two passwords do not match.');
      return;
    }
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      final response = await http
          .post(
            AppConfig.apiUri('/auth/password-reset/confirm'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'token': widget.token, 'new_password': password}),
          )
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() => _isComplete = true);
      } else {
        final data = _decodeJsonObject(response.body);
        setState(() {
          _error = _stringValue(
            data,
            ['detail', 'message'],
            fallback: 'The reset link is invalid or expired.',
          );
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not reach the account server.');
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }
}

class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key, required this.token});

  final String token;

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  bool _isLoading = true;
  bool _verified = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _verify();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Email Verification')),
      body: AppPage(
        children: [
          if (_isLoading)
            const GrammarSkeleton()
          else if (_error != null)
            UnifiedErrorState(
              title: 'Verification failed',
              message: _error!,
              onRetry: _verify,
            )
          else
            CleanCard(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  children: [
                    Icon(
                      _verified
                          ? Icons.verified_rounded
                          : Icons.info_outline_rounded,
                      color: _verified ? kNeonGreen : kElectricBlue,
                      size: 56,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _verified ? 'Email verified' : 'Verification unavailable',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => context.go('/login'),
                      child: const Text('Continue to Login'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _verify() async {
    if (widget.token.length < 32) {
      setState(() {
        _isLoading = false;
        _error = 'This verification link is incomplete.';
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final response = await http
          .post(
            AppConfig.apiUri('/auth/email-verification/confirm'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'token': widget.token}),
          )
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() {
          _verified = true;
          _isLoading = false;
        });
      } else {
        final data = _decodeJsonObject(response.body);
        setState(() {
          _isLoading = false;
          _error = _stringValue(
            data,
            ['detail', 'message'],
            fallback: 'The verification link is invalid or expired.',
          );
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Could not reach the account server.';
      });
    }
  }
}

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static final Uri _initializeEndpoint = AppConfig.apiUri('/user/initialize');

  final List<Map<String, dynamic>> _answers = <Map<String, dynamic>>[];
  int _currentIndex = 0;
  int? _selectedIndex;
  bool _isSubmitting = false;
  bool _profileGenerated = false;
  String? _errorMessage;

  OnboardingQuestion get _currentQuestion =>
      _onboardingQuestions[_currentIndex];

  @override
  Widget build(BuildContext context) {
    final question = _currentQuestion;
    final progress = (_currentIndex + (_selectedIndex == null ? 0 : 1)) /
        _onboardingQuestions.length;

    return Scaffold(
      body: SafeArea(
        child: AppPage(
          children: [
            const SizedBox(height: 8),
            Text(
              '歡迎進行學測起始診斷',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '完成 5 題快速診斷，我們會依結果建立第一組複習單字與能力雷達。',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: kTextTertiary,
                    height: 1.42,
                  ),
            ),
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 7,
                backgroundColor: const Color(0x661B2430),
                valueColor: const AlwaysStoppedAnimation<Color>(kNeonGreen),
              ),
            ),
            const SizedBox(height: 20),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              transitionBuilder: (child, animation) {
                final offset = Tween<Offset>(
                  begin: const Offset(0.08, 0),
                  end: Offset.zero,
                ).animate(animation);
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(position: offset, child: child),
                );
              },
              child: _profileGenerated
                  ? const _ProfileGeneratedCard(key: ValueKey('generated'))
                  : _OnboardingQuestionCard(
                      key: ValueKey(question.id),
                      question: question,
                      selectedIndex: _selectedIndex,
                      isLocked: _isSubmitting,
                      onSelect: _selectAnswer,
                    ),
            ),
            if (_isSubmitting && !_profileGenerated) ...[
              const SizedBox(height: 18),
              const GrammarSkeleton(),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              _StatusBanner(
                message: _errorMessage!,
                icon: Icons.error_outline_rounded,
                color: kDangerRed,
                backgroundColor: kDangerRed,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _selectAnswer(int index) async {
    if (_selectedIndex != null || _isSubmitting) return;

    final question = _currentQuestion;
    final isCorrect = index == question.correctIndex;
    unawaited(_playGrammarAnswerHaptic(isCorrect));

    setState(() {
      _selectedIndex = index;
      _errorMessage = null;
      _answers.add({
        'question_id': question.id,
        'category': question.category,
        'selected_index': index,
        'correct_index': question.correctIndex,
        'is_correct': isCorrect,
      });
    });

    await Future<void>.delayed(const Duration(milliseconds: 420));
    if (!mounted) return;

    if (_currentIndex == _onboardingQuestions.length - 1) {
      await _submitInitialization();
      return;
    }

    setState(() {
      _currentIndex += 1;
      _selectedIndex = null;
    });
  }

  Future<void> _submitInitialization() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final response = await _authenticatedPost(
        _initializeEndpoint,
        body: jsonEncode({'answers': _answers}),
      ).timeout(const Duration(seconds: 18));
      final data = _decodeJsonObject(response.body);

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await HapticFeedback.mediumImpact();
        setState(() {
          _profileGenerated = true;
          _isSubmitting = false;
        });
        await Future<void>.delayed(const Duration(milliseconds: 1650));
        if (!mounted) return;
        ref.read(authControllerProvider).markOnboardingCompleted();
        context.go('/home');
      } else {
        setState(() {
          _errorMessage = _stringValue(
            data,
            ['detail', 'message', 'error'],
            fallback: 'Could not generate your profile yet. Try again.',
          );
          _isSubmitting = false;
          _selectedIndex = null;
          if (_answers.isNotEmpty) _answers.removeLast();
        });
      }
    } on TimeoutException {
      _handleInitializationFailure(
          'Profile generation timed out. Try once more.');
    } on SocketException {
      _handleInitializationFailure(
        'Cannot reach the profile generator. Make sure FastAPI is running.',
      );
    } catch (_) {
      _handleInitializationFailure(
          'Unable to generate your profile right now.');
    }
  }

  void _handleInitializationFailure(String message) {
    if (!mounted) return;
    setState(() {
      _errorMessage = message;
      _isSubmitting = false;
      _selectedIndex = null;
      if (_answers.isNotEmpty) _answers.removeLast();
    });
  }
}

class OnboardingQuestion {
  const OnboardingQuestion({
    required this.id,
    required this.category,
    required this.prompt,
    required this.options,
    required this.correctIndex,
  });

  final String id;
  final String category;
  final String prompt;
  final List<String> options;
  final int correctIndex;
}

const List<OnboardingQuestion> _onboardingQuestions = [
  OnboardingQuestion(
    id: 'vocab-context-1',
    category: 'vocab',
    prompt:
        'The new rule had a significant effect on students. What does significant mean?',
    options: ['tiny', 'important', 'temporary', 'confusing'],
    correctIndex: 1,
  ),
  OnboardingQuestion(
    id: 'grammar-tense-1',
    category: 'grammar',
    prompt: 'Choose the best sentence.',
    options: [
      'She has studied English for three years.',
      'She studied English since three years.',
      'She studies English from three years.',
      'She is study English for three years.',
    ],
    correctIndex: 0,
  ),
  OnboardingQuestion(
    id: 'vocab-academic-1',
    category: 'vocab',
    prompt: 'A sustainable habit is one that can be...',
    options: [
      'continued over time',
      'finished immediately',
      'hidden from others',
      'changed randomly'
    ],
    correctIndex: 0,
  ),
  OnboardingQuestion(
    id: 'grammar-relative-1',
    category: 'grammar',
    prompt: 'Choose the correct relative clause.',
    options: [
      'The student which won the prize is my classmate.',
      'The student who won the prize is my classmate.',
      'The student what won the prize is my classmate.',
      'The student won the prize who is my classmate.',
    ],
    correctIndex: 1,
  ),
  OnboardingQuestion(
    id: 'vocab-chart-1',
    category: 'vocab',
    prompt: 'In chart writing, interpret the data means to...',
    options: [
      'copy every number',
      'explain what the data shows',
      'ignore the trend',
      'decorate the chart'
    ],
    correctIndex: 1,
  ),
];

class _OnboardingQuestionCard extends StatelessWidget {
  const _OnboardingQuestionCard({
    super.key,
    required this.question,
    required this.selectedIndex,
    required this.isLocked,
    required this.onSelect,
  });

  final OnboardingQuestion question;
  final int? selectedIndex;
  final bool isLocked;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: kElectricBlue.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: kElectricBlue.withOpacity(0.35)),
                  ),
                  child: Text(
                    question.category.toUpperCase(),
                    style: const TextStyle(
                      color: kElectricBlue,
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                    ),
                  ),
                ),
                const Spacer(),
                const Icon(Icons.auto_awesome_rounded, color: kNeonGreen),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              question.prompt,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    height: 1.28,
                  ),
            ),
            const SizedBox(height: 18),
            for (var index = 0; index < question.options.length; index++) ...[
              _QuizOptionTile(
                label: String.fromCharCode(65 + index),
                text: question.options[index],
                state: _onboardingOptionState(index, question, selectedIndex),
                onTap: isLocked ? () {} : () => onSelect(index),
              ),
              if (index != question.options.length - 1)
                const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfileGeneratedCard extends StatelessWidget {
  const _ProfileGeneratedCard({super.key});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.84, end: 1),
      duration: const Duration(milliseconds: 760),
      curve: Curves.elasticOut,
      builder: (context, value, child) {
        return Transform.scale(scale: value, child: child);
      },
      child: CleanCard(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            children: [
              Container(
                width: 86,
                height: 86,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: kNeonGreen.withOpacity(0.13),
                  border:
                      Border.all(color: kNeonGreen.withOpacity(0.48), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: kNeonGreen.withOpacity(0.22),
                      blurRadius: 36,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.verified_rounded,
                  color: kNeonGreen,
                  size: 48,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                '學習檔案已建立',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                '你的第一組學測複習卡與能力雷達已準備完成。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: kTextTertiary,
                      height: 1.42,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

_QuizOptionState _onboardingOptionState(
  int index,
  OnboardingQuestion question,
  int? selectedIndex,
) {
  if (selectedIndex == null) return _QuizOptionState.idle;
  if (index == question.correctIndex) return _QuizOptionState.correct;
  if (index == selectedIndex) return _QuizOptionState.wrong;
  return _QuizOptionState.dimmed;
}

class MainScreen extends ConsumerWidget {
  const MainScreen({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  void _goBranch(int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final streak = ref.watch(authControllerProvider).currentStreak;
    final syncController = ref.watch(reviewSyncControllerProvider);
    final isFocusMode = ref.watch(appModeControllerProvider).isFocus;

    return Scaffold(
      appBar: AppBar(
        title: const Text('GSAT_Max'),
        actions: [
          if (navigationShell.currentIndex == 0 ||
              navigationShell.currentIndex == 1) ...[
            const _AppModeToggle(),
            const SizedBox(width: 8),
          ],
          if (syncController.hasPendingActions || syncController.isSyncing) ...[
            _SyncStatusBadge(
              isSyncing: syncController.isSyncing,
              pendingCount: syncController.pendingCount,
              onTap: () => ref.read(reviewSyncControllerProvider).syncNow(),
            ),
            const SizedBox(width: 8),
          ],
          if (navigationShell.currentIndex == 0 && !isFocusMode) ...[
            _DailyStreakBadge(streak: streak),
            const SizedBox(width: 8),
          ],
          IconButton(
            tooltip: '登出',
            onPressed: () => _confirmLogout(context, ref),
            icon: const Icon(Icons.logout_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: TweenAnimationBuilder<double>(
        key: ValueKey(navigationShell.currentIndex),
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) {
          return Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset((1 - value) * 10, 0),
              child: child,
            ),
          );
        },
        child: navigationShell,
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'zen-mode-fab',
        onPressed: () => context.push('/zen'),
        icon: const Icon(Icons.self_improvement_rounded),
        label: const Text('專注'),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: navigationShell.currentIndex,
        onTap: _goBranch,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Theme.of(context).colorScheme.primary,
        unselectedItemColor: kTextTertiary,
        showUnselectedLabels: true,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home_rounded),
            label: '首頁',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.quiz_outlined),
            activeIcon: Icon(Icons.quiz_rounded),
            label: '診斷',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.menu_book_outlined),
            activeIcon: Icon(Icons.menu_book_rounded),
            label: '閱讀',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.edit_note_outlined),
            activeIcon: Icon(Icons.edit_note_rounded),
            label: '寫作',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline_rounded),
            activeIcon: Icon(Icons.person_rounded),
            label: '個人',
          ),
        ],
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('確定要登出嗎？'),
        content: const Text('尚未同步的單字複習會保留在此裝置，登入後可繼續同步。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('登出'),
          ),
        ],
      ),
    );
    if (shouldLogout == true) {
      await ref.read(authControllerProvider).logout();
    }
  }
}

class ZenModeScreen extends StatefulWidget {
  const ZenModeScreen({super.key});

  @override
  State<ZenModeScreen> createState() => _ZenModeScreenState();
}

class _ZenModeScreenState extends State<ZenModeScreen>
    with SingleTickerProviderStateMixin {
  static const Duration _focusDuration = Duration(minutes: 25);
  static const Duration _breakDuration = Duration(minutes: 5);

  late final AnimationController _breathingController;
  Timer? _timer;
  Duration _remaining = _focusDuration;
  bool _isRunning = false;
  bool _isFocusBlock = true;
  AmbientSound _ambientSound = AmbientSound.lofi;

  Duration get _currentDuration =>
      _isFocusBlock ? _focusDuration : _breakDuration;
  double get _progress =>
      1 - (_remaining.inSeconds / math.max(1, _currentDuration.inSeconds));

  @override
  void initState() {
    super.initState();
    _breathingController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
      lowerBound: 0.92,
      upperBound: 1.08,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _breathingController.dispose();
    unawaited(AudioService.instance.stopAmbientLoop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (!_isRunning || !_isFocusBlock) return true;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                  'Focus block is active. Finish or stop the timer first.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !_isRunning || !_isFocusBlock,
          title: const Text('Zen Mode'),
        ),
        body: AppPage(
          children: [
            const PageIntro(
              icon: Icons.self_improvement_rounded,
              title: 'Zen Mode',
              subtitle: '25 minutes of clean focus, then a 5-minute reset.',
            ),
            const SizedBox(height: 28),
            Center(
              child: ScaleTransition(
                scale: _breathingController,
                child: CustomPaint(
                  painter: _ZenProgressPainter(
                    progress: _progress.clamp(0.0, 1.0).toDouble(),
                    color: _isFocusBlock ? kNeonGreen : kElectricBlue,
                  ),
                  child: SizedBox(
                    width: 250,
                    height: 250,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _isFocusBlock ? 'FOCUS' : 'BREAK',
                          style: const TextStyle(
                            color: kTextTertiary,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _formatDuration(_remaining),
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(
                                color: kTextPrimary,
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _isRunning
                              ? 'Breathe in. Hold steady.'
                              : 'Ready when you are.',
                          style: const TextStyle(color: kTextTertiary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 30),
            CleanCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Ambient Sound',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    SegmentedButton<AmbientSound>(
                      segments: const [
                        ButtonSegment(
                          value: AmbientSound.lofi,
                          label: Text('Lofi'),
                          icon: Icon(Icons.graphic_eq_rounded),
                        ),
                        ButtonSegment(
                          value: AmbientSound.rainstorm,
                          label: Text('Rain'),
                          icon: Icon(Icons.water_drop_outlined),
                        ),
                      ],
                      selected: {_ambientSound},
                      onSelectionChanged: _isRunning
                          ? null
                          : (selection) {
                              setState(() => _ambientSound = selection.first);
                            },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Ambient playback is routed through AudioService. Add bundled audio loops to turn this production hook into real sound.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: kTextTertiary,
                            height: 1.35,
                          ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isRunning ? _stopTimer : _startTimer,
                    icon: Icon(_isRunning
                        ? Icons.stop_rounded
                        : Icons.play_arrow_rounded),
                    label: Text(_isRunning ? 'Stop' : 'Start Focus'),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  onPressed: _isRunning ? null : _resetTimer,
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Reset',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startTimer() async {
    setState(() {
      _isRunning = true;
    });
    try {
      await AudioService.instance.playAmbientLoop(_ambientSound);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                  'Ambient audio could not start, but the timer is running.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    }
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining <= const Duration(seconds: 1)) {
        _advanceBlock();
        return;
      }
      setState(() {
        _remaining -= const Duration(seconds: 1);
      });
    });
  }

  Future<void> _stopTimer() async {
    _timer?.cancel();
    await AudioService.instance.stopAmbientLoop();
    if (!mounted) return;
    setState(() {
      _isRunning = false;
    });
  }

  void _resetTimer() {
    setState(() {
      _isFocusBlock = true;
      _remaining = _focusDuration;
    });
  }

  Future<void> _advanceBlock() async {
    _timer?.cancel();
    await AudioService.instance.stopAmbientLoop();
    if (!mounted) return;
    setState(() {
      _isFocusBlock = !_isFocusBlock;
      _remaining = _isFocusBlock ? _focusDuration : _breakDuration;
      _isRunning = false;
    });
    unawaited(HapticFeedback.mediumImpact());
  }
}

class _ZenProgressPainter extends CustomPainter {
  const _ZenProgressPainter({
    required this.progress,
    required this.color,
  });

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 10;
    final basePaint = Paint()
      ..color = Colors.white.withOpacity(0.07)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    final progressPaint = Paint()
      ..shader = SweepGradient(
        colors: [color, kElectricBlue, color],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, basePaint);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      math.pi * 2 * progress,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ZenProgressPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

class _SyncStatusBadge extends StatelessWidget {
  const _SyncStatusBadge({
    required this.isSyncing,
    required this.pendingCount,
    required this.onTap,
  });

  final bool isSyncing;
  final int pendingCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isSyncing ? kElectricBlue : const Color(0xFFFFB020);
    return Tooltip(
      message: isSyncing
          ? 'Syncing review progress'
          : '$pendingCount offline ${pendingCount == 1 ? 'action' : 'actions'} pending',
      child: InkWell(
        onTap: isSyncing ? null : onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF101828),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withOpacity(0.38)),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.14),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isSyncing)
                Icon(Icons.sync_rounded, size: 15, color: color)
              else
                Icon(Icons.cloud_off_rounded, size: 15, color: color),
              const SizedBox(width: 6),
              Text(
                isSyncing ? 'Syncing' : 'Offline',
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppModeToggle extends ConsumerWidget {
  const _AppModeToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appModeControllerProvider);
    final isFocus = controller.isFocus;
    return Tooltip(
      message: isFocus ? 'Focus Mode' : 'Engagement Mode',
      child: InkWell(
        onTap: () => ref.read(appModeControllerProvider).toggle(),
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: 116,
          height: 38,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isFocus ? Colors.black : const Color(0xFF101828),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: isFocus ? Colors.white70 : kNeonGreen.withOpacity(0.42),
            ),
            boxShadow: isFocus
                ? const []
                : [
                    BoxShadow(
                      color: kNeonGreen.withOpacity(0.16),
                      blurRadius: 18,
                      offset: const Offset(0, 7),
                    ),
                  ],
          ),
          child: Stack(
            children: [
              AnimatedAlign(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment:
                    isFocus ? Alignment.centerLeft : Alignment.centerRight,
                child: Container(
                  width: 52,
                  height: 30,
                  decoration: BoxDecoration(
                    color: isFocus ? Colors.white : kNeonGreen,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Center(
                      child: Text(
                        'FOCUS',
                        style: TextStyle(
                          color: isFocus ? Colors.black : kTextTertiary,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        'PLAY',
                        style: TextStyle(
                          color:
                              isFocus ? kTextTertiary : const Color(0xFF07120D),
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DailyStreakBadge extends StatelessWidget {
  const _DailyStreakBadge({required this.streak});

  final int streak;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF101828),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFFF8A00).withOpacity(0.38)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF8A00).withOpacity(0.16),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🔥', style: TextStyle(fontSize: 15)),
          const SizedBox(width: 5),
          Text(
            streak.toString(),
            style: const TextStyle(
              color: Color(0xFFFFB020),
              fontWeight: FontWeight.w900,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class UserStats {
  const UserStats({
    required this.totalWordsMastered,
    required this.averageGrammarScore,
    required this.totalEssaysWritten,
    required this.vocabularySkill,
    required this.grammarSkill,
    required this.readingSkill,
    required this.writingSkill,
  });

  final int totalWordsMastered;
  final double averageGrammarScore;
  final int totalEssaysWritten;
  final double vocabularySkill;
  final double grammarSkill;
  final double readingSkill;
  final double writingSkill;

  factory UserStats.fromJson(Map<String, dynamic> json) {
    return UserStats(
      totalWordsMastered:
          PerformanceMetrics._asInt(json['total_words_mastered']),
      averageGrammarScore:
          PerformanceMetrics._asDouble(json['average_grammar_score']),
      totalEssaysWritten:
          PerformanceMetrics._asInt(json['total_essays_written']),
      vocabularySkill: PerformanceMetrics._asDouble(json['vocabulary_skill']),
      grammarSkill: PerformanceMetrics._asDouble(json['grammar_skill']),
      readingSkill: PerformanceMetrics._asDouble(json['reading_skill']),
      writingSkill: PerformanceMetrics._asDouble(json['writing_skill']),
    );
  }
}

class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key});

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  bool _isPurchasing = false;
  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Upgrade to Pro')),
      body: AppPage(
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: kSurfaceGlassStrong,
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: const Color(0xFFFFC857).withOpacity(0.52)),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFFC857).withOpacity(0.18),
                  blurRadius: 34,
                  offset: const Offset(0, 18),
                ),
                BoxShadow(
                  color: kElectricBlue.withOpacity(0.14),
                  blurRadius: 42,
                  offset: const Offset(0, 24),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFC857).withOpacity(0.15),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFFFFC857)),
                      ),
                      child: const Icon(
                        Icons.workspace_premium_rounded,
                        color: Color(0xFFFFC857),
                        size: 34,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'GSAT_Max Pro',
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(
                                  color: kTextPrimary,
                                  fontWeight: FontWeight.w900,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Unlimited AI practice for the final sprint.',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: kTextSecondary,
                                ),
                          ),
                        ],
                      ),
                    ),
                    const ProBadge(),
                  ],
                ),
                const SizedBox(height: 24),
                const _PaywallFeature(
                  icon: Icons.psychology_alt_rounded,
                  title: 'Unlimited AI Diagnostics',
                  subtitle:
                      'Analyze exam papers and weak points whenever you need.',
                ),
                const _PaywallFeature(
                  icon: Icons.account_tree_outlined,
                  title: 'Unlimited Discourse Generation',
                  subtitle: 'Train 篇章結構 with fresh GSAT-style logic drills.',
                ),
                const _PaywallFeature(
                  icon: Icons.school_outlined,
                  title: 'Infinite Grammar Explanations',
                  subtitle:
                      'Generate targeted explanations without daily limits.',
                ),
                const SizedBox(height: 22),
                if (_errorMessage != null) ...[
                  _StatusBanner(
                    message: _errorMessage!,
                    icon: Icons.error_outline_rounded,
                    color: kDangerRed,
                    backgroundColor: kDangerRed,
                  ),
                  const SizedBox(height: 14),
                ],
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _isPurchasing || auth.isPro ? null : _subscribe,
                    icon: Icon(
                      _isPurchasing
                          ? Icons.hourglass_top_rounded
                          : auth.isPro
                              ? Icons.verified_rounded
                              : Icons.bolt_rounded,
                    ),
                    label: Text(
                      auth.isPro
                          ? 'Pro Active'
                          : _isPurchasing
                              ? 'Activating Pro...'
                              : 'Subscribe to Pro (\$4.99/mo)',
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: _isPurchasing || auth.isPro ? null : _restore,
                  icon: const Icon(Icons.restore_rounded),
                  label: const Text('Restore Purchase'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _subscribe() async {
    setState(() {
      _isPurchasing = true;
      _errorMessage = null;
    });

    try {
      final auth = ref.read(authControllerProvider);
      final userId = auth.userId;
      if (userId == null) throw StateError('Sign in before purchasing Pro.');
      final result =
          await ref.read(purchaseServiceProvider).purchaseMonthly(userId);
      if (!mounted) return;
      if (result.status == PurchaseFlowStatus.cancelled) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.message)),
        );
        return;
      }
      if (result.status != PurchaseFlowStatus.purchased) {
        setState(() => _errorMessage = result.message);
        return;
      }
      final upgraded = await _waitForServerEntitlement(auth);
      if (!mounted) return;
      if (upgraded) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Pro activated. Unlimited AI is unlocked.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        context.go('/profile');
      } else {
        setState(() => _errorMessage =
            'Purchase was received, but secure entitlement sync is still pending. Use Restore Purchase shortly.');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Purchase could not be completed. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isPurchasing = false;
        });
      }
    }
  }

  Future<void> _restore() async {
    setState(() {
      _isPurchasing = true;
      _errorMessage = null;
    });
    try {
      final auth = ref.read(authControllerProvider);
      final userId = auth.userId;
      if (userId == null) {
        throw StateError('Sign in before restoring purchases.');
      }
      final result = await ref.read(purchaseServiceProvider).restore(userId);
      if (!mounted) return;
      if (result.status != PurchaseFlowStatus.restored) {
        setState(() => _errorMessage = result.message);
        return;
      }
      final active = await _waitForServerEntitlement(auth);
      if (!mounted) return;
      if (active) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pro entitlement restored.')),
        );
        context.go('/profile');
      } else {
        setState(() => _errorMessage =
            'No active server-verified Pro entitlement was found yet.');
      }
    } catch (error) {
      if (mounted) setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _isPurchasing = false);
    }
  }

  Future<bool> _waitForServerEntitlement(AuthController auth) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (await auth.syncEntitlement()) return true;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return false;
  }
}

class _PaywallFeature extends StatelessWidget {
  const _PaywallFeature({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: kElectricBlue.withOpacity(0.14),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kElectricBlue.withOpacity(0.38)),
            ),
            child: Icon(icon, color: kElectricBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: kTextTertiary,
                        height: 1.35,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ProBadge extends StatelessWidget {
  const ProBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFFFC857).withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFFFC857).withOpacity(0.62)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFFC857).withOpacity(0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.workspace_premium_rounded,
              size: 15, color: Color(0xFFFFC857)),
          SizedBox(width: 5),
          Text(
            'PRO',
            style: TextStyle(
              color: Color(0xFFFFC857),
              fontWeight: FontWeight.w900,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Terms & Privacy')),
      body: AppPage(
        children: [
          const PageIntro(
            icon: Icons.verified_user_outlined,
            title: 'Legal Center',
            subtitle:
                'Required publishing policies for AI-assisted GSAT English practice.',
          ),
          const SizedBox(height: 18),
          _LegalPolicyCard(
            title: 'Terms of Service',
            icon: Icons.gavel_outlined,
            paragraphs: [
              'This app provides study tools for English GSAT preparation, including AI-generated diagnostics, feedback, practice questions, and study recommendations.',
              'AI-generated evaluations are educational suggestions only. They may contain mistakes, omissions, or inaccurate grading. Students should verify important feedback with teachers, official exam rubrics, or trusted learning resources.',
              'You agree not to upload unlawful, harmful, private, or copyrighted content that you do not have permission to use. Generated content may be reviewed by automated systems to provide learning feedback and safety controls.',
              'We may limit, suspend, or remove access if the service is misused, abused, or used to generate inappropriate content.',
            ],
          ),
          const SizedBox(height: 16),
          _LegalPolicyCard(
            title: 'Privacy Policy',
            icon: Icons.privacy_tip_outlined,
            paragraphs: [
              'We collect account information, learning progress, uploaded study content, AI requests, and app diagnostics only to operate and improve the learning experience.',
              'Uploaded essays, exam images, vocabulary progress, and error ledger entries may be processed by backend services and AI providers to generate feedback. Avoid uploading sensitive personal information.',
              'You can request support, report inappropriate content, and delete your account from Settings. Deleting your account removes your learning data from this service according to backend retention rules.',
              'Crash logs and telemetry are stored locally in this starter build for debugging. Production deployments should connect this architecture to a compliant telemetry provider and publish the final privacy policy URL in store listings.',
            ],
          ),
        ],
      ),
    );
  }
}

class _LegalPolicyCard extends StatelessWidget {
  const _LegalPolicyCard({
    required this.title,
    required this.icon,
    required this.paragraphs,
  });

  final String title;
  final IconData icon;
  final List<String> paragraphs;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: kElectricBlue),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            for (final paragraph in paragraphs) ...[
              Text(
                paragraph,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: kTextSecondary,
                      height: 1.5,
                    ),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  double _speechRate = 0.42;
  TimeOfDay _reminderTime = const TimeOfDay(hour: 20, minute: 0);
  DateTime? _targetExamDate;
  String _weeklyReportPersona = 'Encouraging';
  bool _isLoading = true;
  bool _isDeleting = false;
  int _developerTapCount = 0;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: AppPage(
        children: [
          const PageIntro(
            icon: Icons.settings_rounded,
            title: '設定中心',
            subtitle: '調整語音、提醒、離線資料與帳號安全。',
          ),
          const SizedBox(height: 18),
          if (_isLoading)
            const GrammarSkeleton()
          else ...[
            CleanCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.volume_up_rounded, color: kNeonGreen),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'TTS 語音速度',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        Text(
                          _speechRate.toStringAsFixed(2),
                          style: const TextStyle(
                            color: kNeonGreen,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '較慢的速度適合聽力辨識與跟讀練習。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: kTextTertiary,
                            height: 1.35,
                          ),
                    ),
                    Slider(
                      value: _speechRate,
                      min: 0.1,
                      max: 1.0,
                      divisions: 18,
                      label: _speechRate.toStringAsFixed(2),
                      onChanged: _updateSpeechRate,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            CleanCard(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                leading: const Icon(Icons.notifications_active_outlined),
                title: const Text(
                  '每日提醒時間',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                subtitle: Text(
                  _reminderTime.format(context),
                  style: const TextStyle(color: kTextSecondary),
                ),
                trailing: const Icon(Icons.schedule_rounded),
                onTap: _pickReminderTime,
              ),
            ),
            const SizedBox(height: 16),
            CleanCard(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                leading: const Icon(Icons.event_available_rounded),
                title: const Text(
                  '學測目標日期',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                subtitle: Text(
                  _targetExamDate == null
                      ? '設定考試日期，取得正確的讀書倒數。'
                      : '${_targetExamDate!.year}/${_targetExamDate!.month.toString().padLeft(2, '0')}/${_targetExamDate!.day.toString().padLeft(2, '0')}',
                  style: const TextStyle(color: kTextSecondary),
                ),
                trailing: const Icon(Icons.calendar_month_rounded),
                onTap: _pickTargetExamDate,
              ),
            ),
            const SizedBox(height: 16),
            CleanCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.auto_graph_rounded,
                            color: kElectricBlue),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '每週報告語氣',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'Encouraging',
                          label: Text('Encouraging'),
                          icon: Icon(Icons.favorite_border_rounded),
                        ),
                        ButtonSegment(
                          value: 'Spartan',
                          label: Text('Spartan'),
                          icon: Icon(Icons.shield_outlined),
                        ),
                      ],
                      selected: {_weeklyReportPersona},
                      onSelectionChanged: (selection) {
                        _updateWeeklyReportPersona(selection.first);
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            CleanCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.support_agent_rounded,
                            color: kElectricBlue),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '協助與安全',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '可直接聯絡客服，或回報不適當、錯誤的 AI 內容。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: kTextTertiary,
                            height: 1.35,
                          ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _contactSupport,
                          icon: const Icon(Icons.email_outlined),
                          label: const Text('聯絡客服'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _reportInappropriateContent,
                          icon: const Icon(Icons.flag_outlined),
                          label: const Text('回報不適當內容'),
                        ),
                        TextButton.icon(
                          onPressed: () => context.push('/legal'),
                          icon: const Icon(Icons.policy_outlined),
                          label: const Text('條款與隱私權'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            CleanCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '離線資料',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '清除本機快取單字卡，不會刪除帳號與後端學習進度。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: kTextTertiary,
                            height: 1.35,
                          ),
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: _clearOfflineCache,
                      icon: const Icon(Icons.cleaning_services_outlined),
                      label: const Text('清除離線快取'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: kDangerRed.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kDangerRed.withOpacity(0.7)),
                boxShadow: [
                  BoxShadow(
                    color: kDangerRed.withOpacity(0.16),
                    blurRadius: 24,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: kDangerRed),
                        SizedBox(width: 10),
                        Text(
                          '帳號危險區',
                          style: TextStyle(
                            color: kDangerRed,
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '刪除帳號',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: kDangerRed,
                            fontWeight: FontWeight.w900,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '永久刪除此服務中的帳號與學習資料，此操作無法復原。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: kTextTertiary,
                            height: 1.35,
                          ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: _isDeleting ? null : _confirmDeleteAccount,
                      style: FilledButton.styleFrom(
                        backgroundColor: kDangerRed,
                        foregroundColor: Colors.white,
                      ),
                      icon: Icon(
                        _isDeleting
                            ? Icons.hourglass_top_rounded
                            : Icons.delete_forever_rounded,
                      ),
                      label: Text(
                        _isDeleting ? '刪除中...' : '刪除帳號',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _handleDeveloperTap,
              child: const SizedBox(
                height: 42,
                width: double.infinity,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final rate =
        prefs.getDouble(kTtsSpeechRateKey) ?? AudioService.instance.speechRate;
    final hour = prefs.getInt(kReminderHourKey) ?? 20;
    final minute = prefs.getInt(kReminderMinuteKey) ?? 0;
    final persona = prefs.getString(kWeeklyReportPersonaKey) ?? 'Encouraging';
    DateTime? targetExamDate;
    try {
      final response = await _authenticatedGet(
        AppConfig.apiUri('/user/daily-schedule'),
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        targetExamDate = DateTime.tryParse(
          _stringFromAny(
            _decodeJsonObject(response.body)['target_exam_date'],
            fallback: '',
          ),
        );
      }
    } catch (_) {
      // Audio and notification settings remain usable while offline.
    }
    if (!mounted) return;
    setState(() {
      _speechRate = rate.clamp(0.1, 1.0).toDouble();
      _reminderTime = TimeOfDay(
        hour: hour.clamp(0, 23).toInt(),
        minute: minute.clamp(0, 59).toInt(),
      );
      _weeklyReportPersona = persona == 'Spartan' ? 'Spartan' : 'Encouraging';
      _targetExamDate = targetExamDate;
      _isLoading = false;
    });
  }

  Future<void> _pickTargetExamDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _targetExamDate != null && _targetExamDate!.isAfter(now)
          ? _targetExamDate!
          : now.add(const Duration(days: 90)),
      firstDate: now.add(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 5 * 366)),
    );
    if (picked == null) return;

    try {
      final updatedDate = await TargetExamDateService(
        endpoint: AppConfig.apiUri('/user/target-exam-date'),
      )
          .update(
            requestedDate: picked,
            send: (uri, body) => _authenticatedPatch(uri, body: body),
          )
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() => _targetExamDate = updatedDate);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('GSAT target date updated.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content:
                Text('Could not update the target date. Try again online.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  void _updateSpeechRate(double value) {
    final rate = value.clamp(0.1, 1.0).toDouble();
    setState(() {
      _speechRate = rate;
    });
    unawaited(
      AudioService.instance.setSpeechRate(rate).catchError((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('TTS is unavailable on this device.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }),
    );
  }

  Future<void> _pickReminderTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _reminderTime,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
    if (picked == null) return;

    try {
      await NotificationService.instance.rescheduleDailyReviewReminder(
        hour: picked.hour,
        minute: picked.minute,
      );
      if (!mounted) return;
      setState(() {
        _reminderTime = picked;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Daily reminder set for ${picked.format(context)}.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Could not reschedule notifications on this device.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  Future<void> _updateWeeklyReportPersona(String persona) async {
    final value = persona == 'Spartan' ? 'Spartan' : 'Encouraging';
    setState(() {
      _weeklyReportPersona = value;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kWeeklyReportPersonaKey, value);
  }

  Future<void> _clearOfflineCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kCachedReviewCardsKey);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Offline flashcard cache cleared.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _contactSupport() {
    return _launchSupportEmail(
      subject: 'GSAT_Max Support Request',
      body: 'Hi support team,\n\nI need help with:\n\n',
    );
  }

  Future<void> _reportInappropriateContent() {
    return _launchSupportEmail(
      subject: 'Report Inappropriate AI Content',
      body:
          'Please describe the inappropriate content, where it appeared, and any relevant prompt/result details:\n\n',
    );
  }

  Future<void> _launchSupportEmail({
    required String subject,
    required String body,
  }) async {
    final uri = Uri(
      scheme: 'mailto',
      path: 'support@gsat-english-master.example',
      queryParameters: {
        'subject': subject,
        'body': body,
      },
    );
    try {
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (launched || !mounted) return;
    } catch (_) {
      if (!mounted) return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
              'No email app is available. Please contact support manually.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _confirmDeleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1B1115),
          title: const Text(
            'Delete account?',
            style: TextStyle(color: kDangerRed, fontWeight: FontWeight.w900),
          ),
          content: const Text(
            'This permanently deletes your account and learning data. This action cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: kDangerRed,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    setState(() {
      _isDeleting = true;
    });
    final deleted = await ref.read(authControllerProvider).deleteAccount();
    if (!mounted) return;
    setState(() {
      _isDeleting = false;
    });

    if (deleted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Account deleted.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      context.go('/login');
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              ref.read(authControllerProvider).errorMessage ??
                  'Unable to delete account.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  Future<void> _handleDeveloperTap() async {
    _developerTapCount += 1;
    if (_developerTapCount < 5) return;
    _developerTapCount = 0;
    await _showCrashLogViewer();
  }

  Future<void> _showCrashLogViewer() async {
    final logs = await TelemetryService.instance.readCrashLogs();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          maxChildSize: 0.9,
          minChildSize: 0.36,
          builder: (context, scrollController) {
            return CleanCard(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.bug_report_outlined,
                            color: kElectricBlue),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Developer Crash Logs',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Clear logs',
                          onPressed: () async {
                            await TelemetryService.instance.clearCrashLogs();
                            if (!context.mounted) return;
                            Navigator.of(context).pop();
                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showSnackBar(
                                const SnackBar(
                                  content: Text('Crash logs cleared.'),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                          },
                          icon: const Icon(Icons.delete_sweep_outlined),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: logs.isEmpty
                          ? Center(
                              child: Text(
                                'No anomalies recorded.',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(color: kTextTertiary),
                              ),
                            )
                          : ListView.separated(
                              controller: scrollController,
                              itemCount: logs.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                final log = logs[index];
                                final timestamp =
                                    _nullableString(log['timestamp']) ??
                                        'Unknown time';
                                final source =
                                    _nullableString(log['source']) ?? 'unknown';
                                final error = _nullableString(log['error']) ??
                                    'Unknown error';
                                final stack =
                                    _nullableString(log['stack']) ?? '';
                                final fatal = _boolFromJson(log['fatal']);
                                return ExpansionTile(
                                  tilePadding: EdgeInsets.zero,
                                  collapsedIconColor: kTextSecondary,
                                  iconColor: kElectricBlue,
                                  title: Text(
                                    fatal ? 'Fatal: $source' : source,
                                    style: const TextStyle(
                                      color: kTextPrimary,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  subtitle: Text(
                                    timestamp,
                                    style:
                                        const TextStyle(color: kTextTertiary),
                                  ),
                                  children: [
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: SelectableText(
                                        '$error\n\n$stack',
                                        style: const TextStyle(
                                          color: kTextSecondary,
                                          fontSize: 12,
                                          height: 1.35,
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  static final Uri _statsEndpoint = AppConfig.apiUri('/user/stats');
  static final Uri _cheatSheetEndpoint =
      AppConfig.apiUri('/user/export-cheat-sheet');
  final GlobalKey _radarShareKey = GlobalKey();

  UserStats? _stats;
  bool _isLoading = true;
  bool _isDownloadingCheatSheet = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final stats = _stats;
    final radarValues = stats == null
        ? const [0.1, 0.1, 0.1, 0.1]
        : [
            stats.vocabularySkill.clamp(0.05, 1.0),
            stats.grammarSkill.clamp(0.05, 1.0),
            stats.readingSkill.clamp(0.05, 1.0),
            stats.writingSkill.clamp(0.05, 1.0),
          ];

    return AppPage(
      children: [
        CleanCard(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: kElectricBlue.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kElectricBlue.withOpacity(0.36)),
                  ),
                  child: const Icon(Icons.person_rounded, color: kElectricBlue),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        auth.displayName ?? '學測學習者',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        auth.email ?? 'Signed in',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: kTextTertiary,
                            ),
                      ),
                    ],
                  ),
                ),
                if (auth.isPro) ...[
                  const SizedBox(width: 10),
                  const ProBadge(),
                ] else ...[
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: () => context.push('/paywall'),
                    icon: const Icon(Icons.workspace_premium_rounded),
                    label: const Text('升級 Pro'),
                  ),
                ],
                IconButton(
                  tooltip: '設定',
                  onPressed: () => context.push('/settings'),
                  icon: const Icon(Icons.settings_rounded),
                ),
                IconButton(
                  tooltip: '重新整理統計',
                  onPressed: _isLoading ? null : _loadStats,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        CleanCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: kNeonGreen.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: kNeonGreen.withOpacity(0.32)),
                      ),
                      child: const Icon(
                        Icons.picture_as_pdf_rounded,
                        color: kNeonGreen,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '考前一週弱點講義',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '匯出最需要加強的單字與文法錯題，方便列印衝刺。',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: kTextTertiary,
                                  height: 1.35,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _isDownloadingCheatSheet
                        ? null
                        : _downloadCheatSheetPdf,
                    icon: _isDownloadingCheatSheet
                        ? const Icon(Icons.hourglass_top_rounded)
                        : const Icon(Icons.download_rounded),
                    label: Text(
                      _isDownloadingCheatSheet ? 'PDF 準備中...' : '下載考前弱點講義（PDF）',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_isLoading)
          const _ReviewLoadingState()
        else if (_errorMessage != null)
          _StatusBanner(
            message: _errorMessage!,
            icon: Icons.error_outline_rounded,
            color: kDangerRed,
            backgroundColor: kDangerRed,
          )
        else if (stats != null) ...[
          Row(
            children: [
              Expanded(
                child: _ProfileStatCard(
                  label: '已掌握單字',
                  value: stats.totalWordsMastered.toString(),
                  icon: Icons.bolt_rounded,
                  color: kNeonGreen,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ProfileStatCard(
                  label: '文法平均',
                  value: '${stats.averageGrammarScore.toStringAsFixed(1)}/5',
                  icon: Icons.psychology_alt_rounded,
                  color: kElectricBlue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ProfileStatCard(
            label: '已完成作文',
            value: stats.totalEssaysWritten.toString(),
            icon: Icons.edit_note_rounded,
            color: const Color(0xFFF59E0B),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  '能力雷達',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
              ),
              IconButton(
                tooltip: '分享學習進度',
                onPressed: () => ShareCaptureService.shareBoundary(
                  context: context,
                  boundaryKey: _radarShareKey,
                  fileName: 'gsat-english-skill-radar.png',
                  shareText: 'My GSAT English skill radar from GSAT_Max.',
                ),
                icon: const Icon(
                  Icons.ios_share_rounded,
                  color: kElectricBlue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          RepaintBoundary(
            key: _radarShareKey,
            child: CleanCard(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GSAT Skill Radar',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      height: 260,
                      child: CustomPaint(
                        painter: _SkillRadarPainter(
                          labels: const [
                            'Vocabulary',
                            'Grammar',
                            'Reading',
                            'Writing'
                          ],
                          values: radarValues
                              .map((value) => value.toDouble())
                              .toList(),
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const ShareWatermark(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _loadStats() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await _authenticatedGet(_statsEndpoint)
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;

      final data = _decodeJsonObject(response.body);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() {
          _stats = UserStats.fromJson(data);
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = _stringValue(
            data,
            ['detail', 'message', 'error'],
            fallback: 'Could not load profile stats (${response.statusCode}).',
          );
          _isLoading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to load profile stats right now.';
        _isLoading = false;
      });
    }
  }

  Future<void> _downloadCheatSheetPdf() async {
    setState(() {
      _isDownloadingCheatSheet = true;
    });

    try {
      final response = await _authenticatedGet(_cheatSheetEndpoint).timeout(
        const Duration(seconds: 20),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final data = _decodeJsonObject(response.body);
        throw StateError(
          _stringValue(
            data,
            ['detail', 'message', 'error'],
            fallback: 'PDF export failed with status ${response.statusCode}.',
          ),
        );
      }

      if (kIsWeb) {
        throw UnsupportedError(
          'PDF opening is available in the Android and iOS beta builds.',
        );
      }

      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File(
        '${directory.path}${Platform.pathSeparator}gsat-final-week-cheat-sheet-$timestamp.pdf',
      );
      await file.writeAsBytes(response.bodyBytes, flush: true);
      final openResult = await OpenFile.open(file.path);

      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              openResult.type == ResultType.done
                  ? 'Cheat sheet downloaded and opened.'
                  : 'Cheat sheet saved: ${file.path}',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } on TimeoutException {
      if (!mounted) return;
      _showCheatSheetError('PDF export timed out. Please try again.');
    } on SocketException {
      if (!mounted) return;
      _showCheatSheetError('Cannot reach the backend to export the PDF.');
    } catch (error) {
      if (!mounted) return;
      _showCheatSheetError(error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) {
        setState(() {
          _isDownloadingCheatSheet = false;
        });
      }
    }
  }

  void _showCheatSheetError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

class _ProfileStatCard extends StatelessWidget {
  const _ProfileStatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: kTextTertiary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkillRadarPainter extends CustomPainter {
  const _SkillRadarPainter({
    required this.labels,
    required this.values,
  });

  final List<String> labels;
  final List<double> values;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.34;
    final gridPaint = Paint()
      ..color = kGlassBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = kElectricBlue.withOpacity(0.24)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final fillPaint = Paint()
      ..color = kNeonGreen.withOpacity(0.20)
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = kNeonGreen
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4;

    for (var level = 1; level <= 4; level++) {
      final path = Path();
      for (var index = 0; index < labels.length; index++) {
        final point =
            _pointFor(center, radius * level / 4, index, labels.length);
        if (index == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      path.close();
      canvas.drawPath(path, gridPaint);
    }

    for (var index = 0; index < labels.length; index++) {
      final point = _pointFor(center, radius, index, labels.length);
      canvas.drawLine(center, point, axisPaint);
      _drawLabel(canvas, size, labels[index], point, index);
    }

    final valuePath = Path();
    for (var index = 0; index < labels.length; index++) {
      final value = values[index].clamp(0.0, 1.0).toDouble();
      final point = _pointFor(center, radius * value, index, labels.length);
      if (index == 0) {
        valuePath.moveTo(point.dx, point.dy);
      } else {
        valuePath.lineTo(point.dx, point.dy);
      }
    }
    valuePath.close();
    canvas.drawPath(valuePath, fillPaint);
    canvas.drawPath(valuePath, strokePaint);
  }

  Offset _pointFor(Offset center, double radius, int index, int count) {
    final angle = -math.pi / 2 + (math.pi * 2 * index / count);
    return Offset(
      center.dx + math.cos(angle) * radius,
      center.dy + math.sin(angle) * radius,
    );
  }

  void _drawLabel(
      Canvas canvas, Size size, String label, Offset anchor, int index) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: kTextSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 96);
    final dx = switch (index) {
      1 => anchor.dx + 8,
      3 => anchor.dx - painter.width - 8,
      _ => anchor.dx - painter.width / 2,
    };
    final dy = switch (index) {
      0 => anchor.dy - painter.height - 10,
      2 => anchor.dy + 10,
      _ => anchor.dy - painter.height / 2,
    };
    painter.paint(
      canvas,
      Offset(
        dx.clamp(0.0, size.width - painter.width).toDouble(),
        dy.clamp(0.0, size.height - painter.height).toDouble(),
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _SkillRadarPainter oldDelegate) {
    return oldDelegate.values != values || oldDelegate.labels != labels;
  }
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static final Uri _reviewEndpoint = AppConfig.apiUri('/vocab/review');
  static final Uri _dailyExpansionEndpoint =
      AppConfig.apiUri('/daily-expansion-quiz');
  static final Uri _dailyExpansionSubmitEndpoint =
      AppConfig.apiUri('/daily-expansion-quiz/submit');
  static final Uri _dailyScheduleEndpoint =
      AppConfig.apiUri('/user/daily-schedule');
  static final Uri _weeklyReportEndpoint =
      AppConfig.apiUri('/user/weekly-report');
  final MissionProgressStore _missionProgressStore = MissionProgressStore();

  List<ReviewFlashcard> _queue = const [];
  List<DailyExpansionQuestion> _expansionQuestions = const [];
  final Map<int, int> _expansionAnswers = {};
  final Set<int> _completedMissionIndexes = <int>{};
  StudyMissionSchedule? _missionSchedule;
  String _weeklyReportPersona = 'Encouraging';
  bool _isLoading = true;
  bool _isExpansionLoading = true;
  bool _isMissionLoading = true;
  bool _isSubmittingExpansion = false;
  bool _isLoadingWeeklyReport = false;
  bool _isRating = false;
  bool _isFlipped = false;
  bool _isDismissing = false;
  bool _hasCachedReviewSnapshot = false;
  Offset _dismissOffset = Offset.zero;
  String? _loadError;
  String? _offlineNotice;
  String? _expansionError;
  String? _missionError;

  ReviewFlashcard? get _currentCard => _queue.isEmpty ? null : _queue.first;

  @override
  void initState() {
    super.initState();
    _loadWeeklyReportPersona();
    _loadDailyExpansionGate();
    _loadDailySchedule();
  }

  @override
  Widget build(BuildContext context) {
    final currentCard = _currentCard;

    return AppPage(
      children: [
        if (!_isExpansionLoading && _expansionQuestions.isEmpty) ...[
          if (_isMissionLoading)
            const GrammarSkeleton()
          else if (_missionError != null)
            UnifiedErrorState(
              message: _missionError!,
              title: 'Mission planner needs a refresh',
              onRetry: _loadDailySchedule,
            )
          else if (_missionSchedule != null)
            _TodayMissionDashboard(
              schedule: _missionSchedule!,
              completedIndexes: _completedMissionIndexes,
              isWeeklyReportDay: DateTime.now().weekday == DateTime.sunday,
              isLoadingWeeklyReport: _isLoadingWeeklyReport,
              onToggle: _toggleMissionTask,
              onOpenWeeklyReport: _openWeeklyReport,
              onStartReview: () {
                Scrollable.ensureVisible(
                  context,
                  duration: const Duration(milliseconds: 260),
                );
              },
            ),
          const SizedBox(height: 18),
        ],
        _ReviewHeroHeader(
          dueCount: _queue.length,
          isLoading: _isLoading,
        ),
        if (_offlineNotice != null) ...[
          const SizedBox(height: 12),
          _StatusBanner(
            message: _offlineNotice!,
            icon: Icons.cloud_off_rounded,
            color: kElectricBlue,
            backgroundColor: kElectricBlue,
          ),
        ],
        const SizedBox(height: 18),
        if (_isExpansionLoading)
          const GrammarSkeleton()
        else if (_expansionError != null) ...[
          UnifiedErrorState(
            message: _expansionError!,
            title: 'Expansion quiz needs a refresh',
            onRetry: _loadDailyExpansionGate,
          ),
          const SizedBox(height: 16),
        ] else if (_expansionQuestions.isNotEmpty) ...[
          _DailyExpansionGate(
            questions: _expansionQuestions,
            selectedAnswers: _expansionAnswers,
            isSubmitting: _isSubmittingExpansion,
            onSelect: (questionId, optionIndex) {
              setState(() {
                _expansionAnswers[questionId] = optionIndex;
              });
            },
            onSubmit: _submitDailyExpansionQuiz,
          ),
        ] else if (_loadError != null) ...[
          UnifiedErrorState(
            message: _loadError!,
            title: 'Review deck needs a refresh',
            onRetry: _loadDueWords,
          ),
          const SizedBox(height: 16),
        ],
        if (!_isExpansionLoading &&
            _expansionError == null &&
            _expansionQuestions.isEmpty &&
            _isLoading)
          const _ReviewLoadingState()
        else if (!_isExpansionLoading &&
            _expansionError == null &&
            _expansionQuestions.isEmpty &&
            _loadError == null &&
            currentCard == null)
          const _ReviewCompleteState()
        else if (!_isExpansionLoading &&
            _expansionError == null &&
            _expansionQuestions.isEmpty) ...[
          AnimatedSlide(
            offset: _isDismissing ? _dismissOffset : Offset.zero,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeInBack,
            child: AnimatedOpacity(
              opacity: _isDismissing ? 0 : 1,
              duration: const Duration(milliseconds: 240),
              child: AnimatedScale(
                scale: _isDismissing ? 0.94 : 1,
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                child: FlashcardView(
                  key: ValueKey(currentCard!.id),
                  card: currentCard,
                  onFlipChanged: (isFlipped) {
                    setState(() {
                      _isFlipped = isFlipped;
                    });
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            child: _isFlipped
                ? _MemoryRatingButtons(
                    key: const ValueKey('rating-buttons'),
                    isSubmitting: _isRating,
                    onRate: _rateCurrentCard,
                  )
                : const _FlipPrompt(key: ValueKey('flip-prompt')),
          ),
        ],
      ],
    );
  }

  Future<void> _loadWeeklyReportPersona() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _weeklyReportPersona =
            prefs.getString(kWeeklyReportPersonaKey) ?? 'Encouraging';
      });
    } catch (_) {
      // Default persona is fine.
    }
  }

  Future<void> _loadDailyExpansionGate() async {
    setState(() {
      _isExpansionLoading = true;
      _expansionError = null;
    });

    try {
      final response = await _authenticatedGet(_dailyExpansionEndpoint).timeout(
        const Duration(seconds: 8),
      );
      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = _decodeJsonObject(response.body);
        final rawQuestions = data['questions'];
        final questions = rawQuestions is List
            ? rawQuestions
                .whereType<Map>()
                .map((item) => DailyExpansionQuestion.fromJson(
                    Map<String, dynamic>.from(item)))
                .where((question) => question.options.length >= 2)
                .toList()
            : <DailyExpansionQuestion>[];
        setState(() {
          _expansionQuestions = questions;
          _expansionAnswers.clear();
          _isExpansionLoading = false;
          _expansionError = null;
        });
        if (questions.isEmpty) {
          await _loadDueWords();
        } else {
          setState(() {
            _isLoading = false;
          });
        }
      } else {
        setState(() {
          _isExpansionLoading = false;
          _expansionError =
              'Expansion quiz server returned ${response.statusCode}.';
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _isExpansionLoading = false;
        _expansionError = 'Expansion quiz check timed out.';
      });
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _isExpansionLoading = false;
        _expansionError = 'Cannot reach the expansion quiz server.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isExpansionLoading = false;
        _expansionError = 'Unable to load today\'s expansion quiz.';
      });
    }
  }

  Future<void> _loadDailySchedule() async {
    setState(() {
      _isMissionLoading = true;
      _missionError = null;
    });

    try {
      final response = await _authenticatedGet(_dailyScheduleEndpoint).timeout(
        const Duration(seconds: 8),
      );
      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final schedule =
            StudyMissionSchedule.fromJson(_decodeJsonObject(response.body));
        final userId = _activeAuthController?.userId ?? 0;
        final localOverrides = userId > 0
            ? await _missionProgressStore.readOverrides(
                userId: userId,
                day: DateTime.now(),
              )
            : <int, bool>{};
        if (!mounted) return;
        setState(() {
          _missionSchedule = schedule;
          _completedMissionIndexes
            ..clear()
            ..addAll(
              schedule.tasks
                  .asMap()
                  .entries
                  .where((entry) =>
                      localOverrides[entry.value.id] ??
                      entry.value.status == 'completed')
                  .map((entry) => entry.key),
            );
          _isMissionLoading = false;
          _missionError = null;
        });
        if (userId > 0 && localOverrides.isNotEmpty) {
          unawaited(
            _replayMissionOverrides(
              schedule: schedule,
              userId: userId,
              overrides: localOverrides,
            ),
          );
        }
      } else {
        setState(() {
          _isMissionLoading = false;
          _missionError = 'Planner returned ${response.statusCode}.';
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _isMissionLoading = false;
        _missionError = 'Planner timed out. Try again.';
      });
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _isMissionLoading = false;
        _missionError = 'Cannot reach the study planner server.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isMissionLoading = false;
        _missionError = 'Unable to load today\'s mission.';
      });
    }
  }

  Future<void> _toggleMissionTask(int index) async {
    final schedule = _missionSchedule;
    if (schedule == null || index < 0 || index >= schedule.tasks.length) return;
    final task = schedule.tasks[index];
    final userId = _activeAuthController?.userId ?? 0;
    final wasCompleted = _completedMissionIndexes.contains(index);
    final shouldComplete = !wasCompleted;
    setState(() {
      if (shouldComplete) {
        _completedMissionIndexes.add(index);
      } else {
        _completedMissionIndexes.remove(index);
      }
    });
    unawaited(
      shouldComplete
          ? HapticFeedback.mediumImpact()
          : HapticFeedback.selectionClick(),
    );
    if (userId > 0) {
      await _missionProgressStore.setOverride(
        userId: userId,
        day: DateTime.now(),
        taskId: task.id,
        completed: shouldComplete,
      );
    }

    try {
      final response = await _authenticatedPatch(
        AppConfig.apiUri('/user/daily-schedule/tasks/${task.id}'),
        body: jsonEncode({'completed': shouldComplete}),
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (userId > 0) {
          await _missionProgressStore.clearOverride(
            userId: userId,
            day: DateTime.now(),
            taskId: task.id,
          );
        }
        return;
      }
      throw HttpException('Server returned ${response.statusCode}.');
    } catch (_) {
      if (!mounted) return;
      _showHomeSnack(
        'Task saved on this device. It will sync when the backend is reachable.',
      );
    }
  }

  Future<void> _replayMissionOverrides({
    required StudyMissionSchedule schedule,
    required int userId,
    required Map<int, bool> overrides,
  }) async {
    for (final task in schedule.tasks) {
      final completed = overrides[task.id];
      if (completed == null) continue;
      try {
        final response = await _authenticatedPatch(
          AppConfig.apiUri('/user/daily-schedule/tasks/${task.id}'),
          body: jsonEncode({'completed': completed}),
        ).timeout(const Duration(seconds: 8));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          await _missionProgressStore.clearOverride(
            userId: userId,
            day: DateTime.now(),
            taskId: task.id,
          );
        }
      } catch (_) {
        return;
      }
    }
  }

  Future<void> _openWeeklyReport() async {
    if (_isLoadingWeeklyReport) return;
    await _loadWeeklyReportPersona();
    setState(() {
      _isLoadingWeeklyReport = true;
    });
    try {
      final response = await _authenticatedPost(
        _weeklyReportEndpoint,
        body: jsonEncode({'persona': _weeklyReportPersona}),
      ).timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = _decodeJsonObject(response.body);
        await showDialog<void>(
          context: context,
          builder: (context) => _WeeklyReportDialog(
            persona:
                _stringFromAny(data['persona'], fallback: _weeklyReportPersona),
            report: _stringFromAny(
              data['report'],
              fallback: 'Your weekly report is not ready yet.',
            ),
            metrics: PerformanceMetrics.maybeFromResponse(data),
          ),
        );
      } else if (_isAiQuotaLimitResponse(response)) {
        unawaited(_showAiQuotaBottomSheet(context));
      } else {
        _showHomeSnack(
            'Weekly report failed with status ${response.statusCode}.');
      }
    } on TimeoutException {
      if (mounted) _showHomeSnack('Weekly report timed out. Try again.');
    } catch (_) {
      if (mounted) _showHomeSnack('Unable to generate weekly report.');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingWeeklyReport = false;
        });
      }
    }
  }

  void _showHomeSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _submitDailyExpansionQuiz() async {
    if (_expansionQuestions.isEmpty || _isSubmittingExpansion) return;
    if (_expansionAnswers.length < _expansionQuestions.length) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Answer every expansion question to unlock today.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }

    setState(() {
      _isSubmittingExpansion = true;
    });
    unawaited(HapticFeedback.heavyImpact());

    try {
      final response = await _authenticatedPost(
        _dailyExpansionSubmitEndpoint,
        body: jsonEncode({
          'answers': {
            for (final entry in _expansionAnswers.entries)
              entry.key.toString(): entry.value,
          },
        }),
      ).timeout(const Duration(seconds: 10));
      final data = _decodeJsonObject(response.body);
      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final correct = PerformanceMetrics._asInt(data['correct']);
        final total = PerformanceMetrics._asInt(data['total']);
        unawaited(HapticFeedback.mediumImpact());
        setState(() {
          _expansionQuestions = const [];
          _expansionAnswers.clear();
          _isSubmittingExpansion = false;
        });
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Expansion complete: $correct / $total correct.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        await _loadDueWords();
      } else {
        setState(() {
          _isSubmittingExpansion = false;
          _expansionError = 'Submit failed with status ${response.statusCode}.';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSubmittingExpansion = false;
        _expansionError = 'Unable to submit expansion quiz. Try again.';
      });
    }
  }

  Future<void> _loadDueWords() async {
    final cachedCards = await _loadCachedReviewCards();
    if (!mounted) return;

    setState(() {
      _queue = cachedCards;
      _isLoading = cachedCards.isEmpty;
      _loadError = null;
      _offlineNotice = null;
    });

    try {
      unawaited(ref.read(reviewSyncControllerProvider).syncNow());
      final response = await _authenticatedGet(_reviewEndpoint).timeout(
        const Duration(seconds: 8),
      );

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        final items = decoded is List ? decoded : const [];
        final cards = items
            .whereType<Map>()
            .map((item) =>
                ReviewFlashcard.fromJson(Map<String, dynamic>.from(item)))
            .toList();

        setState(() {
          _queue = cards;
          _isLoading = false;
          _loadError = null;
          _offlineNotice = null;
        });
        await _cacheReviewCards(cards);
        if (cards.isEmpty) {
          unawaited(NotificationService.instance.cancelTodaysReviewReminder());
        }
      } else {
        _useOfflineCache(
          cachedCards,
          'Review server returned ${response.statusCode}; using cached cards.',
        );
      }
    } on TimeoutException {
      if (!mounted) return;
      _useOfflineCache(cachedCards, 'Offline mode: review server timed out.');
    } on SocketException {
      if (!mounted) return;
      _useOfflineCache(cachedCards, 'Offline mode: backend is unreachable.');
    } catch (_) {
      if (!mounted) return;
      _useOfflineCache(cachedCards, 'Offline mode: using local review cache.');
    }
  }

  void _useOfflineCache(
    List<ReviewFlashcard> cachedCards,
    String message,
  ) {
    setState(() {
      _queue = cachedCards;
      _isLoading = false;
      _loadError = _hasCachedReviewSnapshot ? null : message;
      _offlineNotice = _hasCachedReviewSnapshot
          ? cachedCards.isEmpty
              ? 'Offline: your last synced deck has no due cards.'
              : '$message Progress is saved locally until sync resumes.'
          : null;
    });
  }

  Future<List<ReviewFlashcard>> _loadCachedReviewCards() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kCachedReviewCardsKey);
      _hasCachedReviewSnapshot = raw != null;
      if (raw == null || raw.trim().isEmpty) return const [];
      final decoded = jsonDecode(raw);
      final items = decoded is List ? decoded : const [];
      return items
          .whereType<Map>()
          .map((item) =>
              ReviewFlashcard.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _cacheReviewCards(List<ReviewFlashcard> cards) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _hasCachedReviewSnapshot = true;
      await prefs.setString(
        kCachedReviewCardsKey,
        jsonEncode(cards.map((card) => card.toJson()).toList()),
      );
    } catch (_) {
      // Cache failures should not block review.
    }
  }

  Future<void> _rateCurrentCard(_MemoryRating rating) async {
    final card = _currentCard;
    if (card == null || _isRating) return;

    setState(() {
      _isRating = true;
    });

    await ref.read(reviewSyncControllerProvider).enqueueReview(
          vocabId: card.vocabId,
          quality: rating.quality,
        );

    if (!mounted) return;

    setState(() {
      _dismissOffset = rating.dismissOffset;
      _isDismissing = true;
    });

    await Future<void>.delayed(const Duration(milliseconds: 330));

    if (!mounted) return;

    setState(() {
      _queue = _queue.skip(1).toList();
      _isRating = false;
      _isFlipped = false;
      _isDismissing = false;
      _dismissOffset = Offset.zero;
    });
    unawaited(_cacheReviewCards(_queue));

    if (_queue.isEmpty) {
      unawaited(NotificationService.instance.cancelTodaysReviewReminder());
    }
  }
}

class _TodayMissionDashboard extends StatelessWidget {
  const _TodayMissionDashboard({
    required this.schedule,
    required this.completedIndexes,
    required this.isWeeklyReportDay,
    required this.isLoadingWeeklyReport,
    required this.onToggle,
    required this.onOpenWeeklyReport,
    required this.onStartReview,
  });

  final StudyMissionSchedule schedule;
  final Set<int> completedIndexes;
  final bool isWeeklyReportDay;
  final bool isLoadingWeeklyReport;
  final ValueChanged<int> onToggle;
  final VoidCallback onOpenWeeklyReport;
  final VoidCallback onStartReview;

  @override
  Widget build(BuildContext context) {
    final total = schedule.tasks.length;
    final completed = completedIndexes.length.clamp(0, total).toInt();
    final progress = total == 0 ? 0.0 : completed / total;
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: (isWeeklyReportDay ? kElectricBlue : kNeonGreen)
                        .withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (isWeeklyReportDay ? kElectricBlue : kNeonGreen)
                          .withOpacity(0.42),
                    ),
                  ),
                  child: Icon(
                    isWeeklyReportDay
                        ? Icons.auto_graph_rounded
                        : Icons.trending_up_rounded,
                    color: isWeeklyReportDay ? kElectricBlue : kNeonGreen,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isWeeklyReportDay ? '本週學習報告' : '今日任務',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isWeeklyReportDay
                            ? '週日回顧已就緒 · 本週重點：${_conceptLabel(schedule.focusSkill)}'
                            : 'AI 安排的衝刺任務 · 今日重點：${_conceptLabel(schedule.focusSkill)}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: kTextTertiary,
                              height: 1.35,
                            ),
                      ),
                    ],
                  ),
                ),
                _CountdownChip(daysRemaining: schedule.daysRemaining),
              ],
            ),
            if (isWeeklyReportDay) ...[
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: isLoadingWeeklyReport ? null : onOpenWeeklyReport,
                  icon: Icon(
                    isLoadingWeeklyReport
                        ? Icons.hourglass_top_rounded
                        : Icons.article_rounded,
                  ),
                  label: Text(
                    isLoadingWeeklyReport ? '報告產生中...' : '開啟本週報告',
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '已完成 $completed / $total 項任務',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: kTextSecondary,
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                ),
                Text(
                  '${(progress * 100).round()}%',
                  style: const TextStyle(
                    color: kNeonGreen,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Stack(
                children: [
                  Container(height: 14, color: Colors.white.withOpacity(0.06)),
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: 0,
                      end: progress.clamp(0.0, 1.0).toDouble(),
                    ),
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, child) {
                      return FractionallySizedBox(
                        widthFactor: value,
                        alignment: Alignment.centerLeft,
                        child: child,
                      );
                    },
                    child: Container(
                      height: 14,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [kElectricBlue, kNeonGreen],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Countdown Curve',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: kTextSecondary,
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Stack(
                children: [
                  Container(height: 12, color: Colors.white.withOpacity(0.06)),
                  FractionallySizedBox(
                    widthFactor:
                        schedule.upwardCurve.clamp(0.04, 1.0).toDouble(),
                    child: Container(
                      height: 12,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [kElectricBlue, kNeonGreen],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '距離考試日的學習曲線已推進 ${(schedule.upwardCurve * 100).round()}%',
              style: const TextStyle(color: kTextTertiary, fontSize: 12),
            ),
            const SizedBox(height: 18),
            for (var index = 0; index < schedule.tasks.length; index++) ...[
              _MissionTaskRow(
                task: schedule.tasks[index],
                isCompleted: completedIndexes.contains(index),
                onTap: () => onToggle(index),
              ),
              if (index != schedule.tasks.length - 1)
                const SizedBox(height: 10),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onStartReview,
                icon: const Icon(Icons.style_rounded),
                label: const Text('開始單字複習'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MissionTaskRow extends StatelessWidget {
  const _MissionTaskRow({
    required this.task,
    required this.isCompleted,
    required this.onTap,
  });

  final StudyMissionTask task;
  final bool isCompleted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = _missionTaskLabel(task);
    final meta = _missionTaskMeta(task);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isCompleted
              ? kNeonGreen.withOpacity(0.10)
              : Colors.white.withOpacity(0.035),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isCompleted ? kNeonGreen.withOpacity(0.65) : kGlassBorder,
          ),
        ),
        child: Row(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Icon(
                isCompleted
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                key: ValueKey(isCompleted),
                color: isCompleted ? kNeonGreen : kTextTertiary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: isCompleted ? kNeonGreen : kTextPrimary,
                      fontWeight: FontWeight.w900,
                      decoration:
                          isCompleted ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      meta,
                      style:
                          const TextStyle(color: kTextTertiary, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            if (task.priority == 'high')
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: kElectricBlue.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: kElectricBlue.withOpacity(0.38)),
                ),
                child: const Text(
                  'HIGH',
                  style: TextStyle(
                    color: kElectricBlue,
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WeeklyReportDialog extends StatelessWidget {
  const _WeeklyReportDialog({
    required this.persona,
    required this.report,
    this.metrics,
  });

  final String persona;
  final String report;
  final PerformanceMetrics? metrics;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(18),
      child: CleanCard(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_graph_rounded, color: kElectricBlue),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '$persona Weekly Report',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (metrics != null)
                    InferenceBadge(
                      totalTimeSeconds: metrics!.totalTimeSeconds,
                      tokensPerSecond: metrics!.tokensPerSecond,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: SingleChildScrollView(
                  child: _TypewriterText(
                    text: report,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: kTextSecondary,
                          height: 1.55,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Lock in next week'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypewriterText extends StatefulWidget {
  const _TypewriterText({required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<_TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<_TypewriterText> {
  Timer? _timer;
  int _visibleCharacters = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 18), (_) {
      if (!mounted) return;
      if (_visibleCharacters >= widget.text.length) {
        _timer?.cancel();
        return;
      }
      setState(() {
        _visibleCharacters =
            math.min(widget.text.length, _visibleCharacters + 2);
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      widget.text.substring(0, _visibleCharacters),
      style: widget.style,
    );
  }
}

class _CountdownChip extends StatelessWidget {
  const _CountdownChip({required this.daysRemaining});

  final int daysRemaining;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: kElectricBlue.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kElectricBlue.withOpacity(0.42)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            daysRemaining.toString(),
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: kElectricBlue,
                  fontWeight: FontWeight.w900,
                ),
          ),
          const Text(
            'days',
            style: TextStyle(
              color: kTextTertiary,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

String _missionTaskLabel(StudyMissionTask task) {
  return switch (task.type) {
    'vocab' => '單字衝刺',
    'grammar' || 'grammar_concept' => '文法觀念訓練',
    'mixed_questions' => '混合題訓練',
    'reading_practice' => '閱讀練習',
    'writing_sprint' => '寫作衝刺',
    'final_review' => '考前總複習',
    _ => _conceptLabel(task.type),
  };
}

String _missionTaskMeta(StudyMissionTask task) {
  final parts = <String>[];
  if (task.count != null) parts.add('${task.count} 題');
  if (task.minutes != null) parts.add('${task.minutes} 分鐘');
  if (task.topic != null) parts.add(task.topic!);
  return parts.join(' · ');
}

class _DailyExpansionGate extends StatelessWidget {
  const _DailyExpansionGate({
    required this.questions,
    required this.selectedAnswers,
    required this.isSubmitting,
    required this.onSelect,
    required this.onSubmit,
  });

  final List<DailyExpansionQuestion> questions;
  final Map<int, int> selectedAnswers;
  final bool isSubmitting;
  final void Function(int questionId, int optionIndex) onSelect;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: kElectricBlue.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kElectricBlue.withOpacity(0.4)),
                  ),
                  child: const Icon(
                    Icons.psychology_alt_rounded,
                    color: kElectricBlue,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Daily Expansion Quiz',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Complete these 舉一反三 questions from yesterday\'s scan to unlock today\'s practice.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: kTextTertiary,
                              height: 1.35,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            for (var index = 0; index < questions.length; index++) ...[
              _ExpansionQuestionBlock(
                number: index + 1,
                question: questions[index],
                selectedIndex: selectedAnswers[questions[index].id],
                onSelect: (optionIndex) =>
                    onSelect(questions[index].id, optionIndex),
              ),
              if (index != questions.length - 1) const SizedBox(height: 14),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: isSubmitting ? null : onSubmit,
                icon: Icon(
                  isSubmitting
                      ? Icons.hourglass_top_rounded
                      : Icons.lock_open_rounded,
                ),
                label: Text(isSubmitting
                    ? 'Submitting...'
                    : 'Complete and unlock today'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpansionQuestionBlock extends StatelessWidget {
  const _ExpansionQuestionBlock({
    required this.number,
    required this.question,
    required this.selectedIndex,
    required this.onSelect,
  });

  final int number;
  final DailyExpansionQuestion question;
  final int? selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0x661B2430),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kGlassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Q$number · ${_conceptLabel(question.concept)}',
            style: const TextStyle(
              color: kNeonGreen,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            question.question,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: kTextPrimary,
                  height: 1.35,
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 10),
          for (var index = 0; index < question.options.length; index++) ...[
            _ExpansionOptionTile(
              label: question.options[index],
              isSelected: selectedIndex == index,
              onTap: () => onSelect(index),
            ),
            if (index != question.options.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _ExpansionOptionTile extends StatelessWidget {
  const _ExpansionOptionTile({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? kNeonGreen.withOpacity(0.12)
              : Colors.white.withOpacity(0.03),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? kNeonGreen.withOpacity(0.7) : kGlassBorder,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? kNeonGreen : kTextTertiary,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? kTextPrimary : kTextSecondary,
                  fontWeight: isSelected ? FontWeight.w900 : FontWeight.w700,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ReviewFlashcard {
  const ReviewFlashcard({
    required this.id,
    required this.vocabId,
    required this.word,
    required this.meaning,
    required this.exampleSentence,
    required this.interval,
    required this.repetitions,
    required this.easeFactor,
    this.metrics,
  });

  final String id;
  final int vocabId;
  final String word;
  final String meaning;
  final String exampleSentence;
  final int interval;
  final int repetitions;
  final double easeFactor;
  final PerformanceMetrics? metrics;

  bool get wasPreviouslyHard =>
      easeFactor < 2.5 || (repetitions == 0 && interval <= 1);

  factory ReviewFlashcard.fromJson(Map<String, dynamic> json) {
    final vocabId = PerformanceMetrics._asInt(json['vocab_id']);
    final word = _stringFromJson(json, ['word'], fallback: 'unknown');
    final definition = _stringFromJson(
      json,
      ['definition', 'meaning', 'chinese_meaning'],
      fallback: '尚未提供中文解釋',
    );
    final example = _stringFromJson(
      json,
      ['example_sentence', 'source_context', 'example'],
      fallback: 'Try using "$word" in your own sentence today.',
    );

    return ReviewFlashcard(
      id: '$vocabId-$word',
      vocabId: vocabId,
      word: word,
      meaning: definition,
      exampleSentence: example,
      interval: PerformanceMetrics._asInt(json['interval']),
      repetitions: PerformanceMetrics._asInt(json['repetitions']),
      easeFactor: json['ease_factor'] == null
          ? 2.5
          : PerformanceMetrics._asDouble(json['ease_factor']),
      metrics: PerformanceMetrics.maybeFromResponse(json),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'vocab_id': vocabId,
      'word': word,
      'definition': meaning,
      'source_context': exampleSentence,
      'interval': interval,
      'repetitions': repetitions,
      'ease_factor': easeFactor,
      if (metrics != null)
        'performance_metrics': {
          'total_time_seconds': metrics!.totalTimeSeconds,
          'tokens_per_second': metrics!.tokensPerSecond,
          'total_tokens': metrics!.totalTokens,
        },
    };
  }
}

class VocabMnemonic {
  const VocabMnemonic({
    required this.etymology,
    required this.taiwaneseMnemonic,
    this.metrics,
  });

  final String etymology;
  final String taiwaneseMnemonic;
  final PerformanceMetrics? metrics;

  factory VocabMnemonic.fromJson(Map<String, dynamic> json) {
    return VocabMnemonic(
      etymology: _stringFromJson(
        json,
        ['etymology', 'roots'],
        fallback: 'No etymology was generated yet.',
      ),
      taiwaneseMnemonic: _stringFromJson(
        json,
        ['taiwanese_mnemonic', 'mnemonic'],
        fallback: 'Try making your own funny sound hook for this word.',
      ),
      metrics: PerformanceMetrics.maybeFromResponse(json),
    );
  }
}

String _stringFromJson(
  Map<String, dynamic> json,
  List<String> keys, {
  required String fallback,
}) {
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return fallback;
}

enum _MemoryRating {
  hard('困難（再複習）', Icons.refresh_rounded, Color(0xFFDC2626), 2, Offset(-1.4, 0)),
  good('記得（1 天）', Icons.thumb_up_alt_outlined, Color(0xFF2563EB), 4,
      Offset(1.4, 0)),
  easy('簡單（4 天）', Icons.rocket_launch_outlined, Color(0xFF047857), 5,
      Offset(0, -1.2));

  const _MemoryRating(
    this.label,
    this.icon,
    this.color,
    this.quality,
    this.dismissOffset,
  );

  final String label;
  final IconData icon;
  final Color color;
  final int quality;
  final Offset dismissOffset;
}

class _ReviewHeroHeader extends StatelessWidget {
  const _ReviewHeroHeader({
    required this.dueCount,
    required this.isLoading,
  });

  final int dueCount;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: kSurfaceGlassStrong,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kGlassBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: const Color(0xFF36F3A5).withOpacity(0.16),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.bolt_rounded,
              color: Color(0xFF36F3A5),
              size: 32,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '單字複習場',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: kTextPrimary,
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  isLoading ? '正在載入今日複習卡...' : '今天還有 $dueCount 張待複習單字卡',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: kTextSecondary,
                      ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '錯題本',
            onPressed: () => context.push('/error-ledger'),
            icon: const Icon(Icons.fact_check_outlined),
          ),
          const SizedBox(width: 4),
          _ReviewCounter(value: isLoading ? '--' : dueCount.toString()),
        ],
      ),
    );
  }
}

class _ReviewCounter extends StatelessWidget {
  const _ReviewCounter({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 58,
      height: 58,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFF36F3A5), width: 2),
      ),
      child: Text(
        value,
        style: const TextStyle(
          color: Color(0xFF36F3A5),
          fontSize: 20,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class FlashcardView extends StatefulWidget {
  const FlashcardView({
    super.key,
    required this.card,
    required this.onFlipChanged,
  });

  final ReviewFlashcard card;
  final ValueChanged<bool> onFlipChanged;

  @override
  State<FlashcardView> createState() => _FlashcardViewState();
}

class _FlashcardViewState extends State<FlashcardView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _flipAnimation;
  bool _isFlipped = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _flipAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _toggleFlip,
      child: AnimatedBuilder(
        animation: _flipAnimation,
        builder: (context, child) {
          final angle = _flipAnimation.value * math.pi;
          final showBack = angle > math.pi / 2;

          return Transform(
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0014)
              ..rotateY(angle),
            alignment: Alignment.center,
            child: showBack
                ? Transform(
                    transform: Matrix4.identity()..rotateY(math.pi),
                    alignment: Alignment.center,
                    child: _FlashcardBack(card: widget.card),
                  )
                : _FlashcardFront(card: widget.card),
          );
        },
      ),
    );
  }

  void _toggleFlip() {
    unawaited(HapticFeedback.lightImpact());

    if (_isFlipped) {
      _controller.reverse();
    } else {
      _controller.forward();
    }

    setState(() {
      _isFlipped = !_isFlipped;
    });
    widget.onFlipChanged(_isFlipped);
  }
}

class _FlashcardFront extends StatelessWidget {
  const _FlashcardFront({required this.card});

  final ReviewFlashcard card;

  @override
  Widget build(BuildContext context) {
    return _FlashcardShell(
      color: const Color(0xFF101828),
      borderColor: const Color(0xFF36F3A5).withOpacity(0.42),
      child: Stack(
        children: [
          Positioned(
            right: 18,
            top: 18,
            child: SpeakerIconButton(
              text: card.word,
              tooltip: 'Speak ${card.word}',
              compact: true,
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  card.word,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 14),
                Container(
                  width: 92,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF36F3A5),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FlashcardBack extends ConsumerWidget {
  const _FlashcardBack({required this.card});

  final ReviewFlashcard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showBrainHack =
        !ref.watch(appModeControllerProvider).isFocus && card.wasPreviouslyHard;
    return _FlashcardShell(
      color: kSurfaceGlassStrong,
      borderColor: kGlassBorder,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    card.word,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                ),
                SpeakerIconButton(
                  text: card.word,
                  tooltip: 'Speak ${card.word}',
                  compact: true,
                ),
                if (card.metrics != null) const SizedBox(width: 10),
                if (card.metrics != null)
                  InferenceBadge(
                    totalTimeSeconds: card.metrics!.totalTimeSeconds,
                    tokensPerSecond: card.metrics!.tokensPerSecond,
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              card.meaning,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0x661B2430),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kGlassBorder),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.format_quote_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      card.exampleSentence,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: kTextSecondary,
                            height: 1.45,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ],
              ),
            ),
            if (showBrainHack) ...[
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: _BrainHackButton(card: card),
              ),
            ],
            const Spacer(),
            Row(
              children: [
                const Icon(Icons.stars_rounded, color: Color(0xFFF59E0B)),
                const SizedBox(width: 8),
                Text(
                  'Combo ready',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: kTextTertiary,
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BrainHackButton extends StatefulWidget {
  const _BrainHackButton({required this.card});

  final ReviewFlashcard card;

  @override
  State<_BrainHackButton> createState() => _BrainHackButtonState();
}

class _BrainHackButtonState extends State<_BrainHackButton> {
  static final Uri _mnemonicEndpoint =
      AppConfig.apiUri('/generate/vocab-mnemonic');

  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: _isLoading ? null : _openBrainHack,
      icon: Icon(
          _isLoading ? Icons.hourglass_top_rounded : Icons.psychology_rounded),
      label: Text(_isLoading ? 'Loading...' : 'Brain Hack 🧠'),
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFFFC857),
        foregroundColor: const Color(0xFF1A1200),
        minimumSize: const Size(0, 42),
        shadowColor: const Color(0xFFFFC857).withOpacity(0.45),
        elevation: 8,
      ),
    );
  }

  Future<void> _openBrainHack() async {
    setState(() {
      _isLoading = true;
    });
    try {
      final response = await _authenticatedPost(
        _mnemonicEndpoint,
        body: jsonEncode({
          'word': widget.card.word,
          'definition': widget.card.meaning,
          'source_context': widget.card.exampleSentence,
        }),
      ).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final mnemonic =
            VocabMnemonic.fromJson(_decodeJsonObject(response.body));
        await showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          backgroundColor: Colors.transparent,
          builder: (context) => _MnemonicBottomSheet(
            word: widget.card.word,
            mnemonic: mnemonic,
          ),
        );
      } else if (_isAiQuotaLimitResponse(response)) {
        unawaited(_showAiQuotaBottomSheet(context));
      } else {
        _showSnack('Brain Hack failed with status ${response.statusCode}.');
      }
    } on TimeoutException {
      if (mounted) _showSnack('Brain Hack timed out. Try again.');
    } catch (_) {
      if (mounted) _showSnack('Unable to generate this mnemonic.');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }
}

class _MnemonicBottomSheet extends StatelessWidget {
  const _MnemonicBottomSheet({
    required this.word,
    required this.mnemonic,
  });

  final String word;
  final VocabMnemonic mnemonic;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: CleanCard(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.psychology_rounded,
                        color: Color(0xFFFFC857)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Brain Hack: $word',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (mnemonic.metrics != null)
                      InferenceBadge(
                        totalTimeSeconds: mnemonic.metrics!.totalTimeSeconds,
                        tokensPerSecond: mnemonic.metrics!.tokensPerSecond,
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                _MnemonicBlock(
                  title: 'Etymology',
                  body: mnemonic.etymology,
                  icon: Icons.account_tree_rounded,
                ),
                const SizedBox(height: 12),
                _MnemonicBlock(
                  title: 'Taiwanese Hook',
                  body: mnemonic.taiwaneseMnemonic,
                  icon: Icons.bolt_rounded,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MnemonicBlock extends StatelessWidget {
  const _MnemonicBlock({
    required this.title,
    required this.body,
    required this.icon,
  });

  final String title;
  final String body;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kGlassBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: kNeonGreen),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: kTextSecondary,
                        height: 1.45,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FlashcardShell extends StatelessWidget {
  const _FlashcardShell({
    required this.child,
    required this.color,
    required this.borderColor,
  });

  final Widget child;
  final Color color;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 330,
      width: double.infinity,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 28,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _MemoryRatingButtons extends StatelessWidget {
  const _MemoryRatingButtons({
    super.key,
    required this.isSubmitting,
    required this.onRate,
  });

  final bool isSubmitting;
  final ValueChanged<_MemoryRating> onRate;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final useRow = constraints.maxWidth > 680;
        final buttons = [
          for (final rating in _MemoryRating.values)
            _RatingButton(
              rating: rating,
              isSubmitting: isSubmitting,
              onPressed: () {
                unawaited(HapticFeedback.heavyImpact());
                onRate(rating);
              },
            ),
        ];

        if (useRow) {
          return Row(
            children: [
              for (var index = 0; index < buttons.length; index++) ...[
                Expanded(child: buttons[index]),
                if (index != buttons.length - 1) const SizedBox(width: 10),
              ],
            ],
          );
        }

        return Column(
          children: [
            for (var index = 0; index < buttons.length; index++) ...[
              buttons[index],
              if (index != buttons.length - 1) const SizedBox(height: 10),
            ],
          ],
        );
      },
    );
  }
}

class _RatingButton extends StatelessWidget {
  const _RatingButton({
    required this.rating,
    required this.isSubmitting,
    required this.onPressed,
  });

  final _MemoryRating rating;
  final bool isSubmitting;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: isSubmitting ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: rating.color,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: isSubmitting
          ? const Icon(Icons.hourglass_top_rounded)
          : Icon(rating.icon),
      label: Text(
        rating.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
    );
  }
}

class _FlipPrompt extends StatelessWidget {
  const _FlipPrompt({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: Center(
        child: Container(
          width: 84,
          height: 6,
          decoration: BoxDecoration(
            color: const Color(0xFFD9E2EF),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
    );
  }
}

class _ReviewLoadingState extends StatelessWidget {
  const _ReviewLoadingState();

  @override
  Widget build(BuildContext context) {
    return const FlashcardSkeleton();
  }
}

class _ReviewCompleteState extends StatelessWidget {
  const _ReviewCompleteState();

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.86, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.elasticOut,
      builder: (context, scale, child) {
        return Transform.scale(scale: scale, child: child);
      },
      child: CleanCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 34),
          child: Column(
            children: [
              Container(
                width: 86,
                height: 86,
                decoration: BoxDecoration(
                  color: const Color(0xFFECFDF5),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF36F3A5), width: 2),
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: Color(0xFF047857),
                  size: 54,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '今天的複習全部完成！',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                '做得很好，明天再回來延續你的學習節奏。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: kTextTertiary,
                      height: 1.4,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class GrammarQuizScreen extends StatefulWidget {
  const GrammarQuizScreen({super.key});

  @override
  State<GrammarQuizScreen> createState() => _GrammarQuizScreenState();
}

class _GrammarQuizScreenState extends State<GrammarQuizScreen> {
  static final Uri _grammarEndpoint = AppConfig.apiUri('/generate/grammar');
  static final Uri _ledgerEndpoint = AppConfig.apiUri('/grammar/error-ledger');

  GrammarQuizQuestion? _quiz;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isSaved = false;
  int? _selectedIndex;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadQuiz();
  }

  @override
  Widget build(BuildContext context) {
    final quiz = _quiz;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Grammar Quiz'),
        actions: [
          if (quiz != null)
            IconButton(
              tooltip: 'Save to Error Ledger',
              onPressed: _isSaving ? null : _saveToLedger,
              icon: _isSaving
                  ? const Icon(Icons.hourglass_top_rounded)
                  : Icon(
                      _isSaved
                          ? Icons.bookmark_added_rounded
                          : Icons.bookmark_add_outlined,
                    ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
          children: [
            if (_isLoading)
              const Hero(
                tag: 'grammar-quiz-flow',
                child: Material(
                  color: Colors.transparent,
                  child: _GlowingQuizLoader(),
                ),
              )
            else if (_errorMessage != null)
              Hero(
                tag: 'grammar-quiz-flow',
                child: Material(
                  color: Colors.transparent,
                  child: _QuizErrorState(
                    message: _errorMessage!,
                    onRetry: _loadQuiz,
                  ),
                ),
              )
            else if (quiz != null) ...[
              Hero(
                tag: 'grammar-quiz-flow',
                child: Material(
                  color: Colors.transparent,
                  child: _GrammarQuestionCard(
                    quiz: quiz,
                    selectedIndex: _selectedIndex,
                    onSelect: _selectOption,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                child: _selectedIndex == null
                    ? const _QuizHintCard(key: ValueKey('hint'))
                    : _GrammarExplanationCard(
                        key: const ValueKey('explanation'),
                        explanation: quiz.explanation,
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _loadQuiz() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _quiz = null;
      _selectedIndex = null;
      _isSaved = false;
    });

    try {
      final response = await _authenticatedPost(
        _grammarEndpoint,
        body: jsonEncode({
          'mode': 'quiz',
          'sentence':
              'Generate one GSAT-style multiple-choice grammar question for a Taiwanese high school student.',
        }),
      ).timeout(const Duration(seconds: 20));

      if (!mounted) return;

      final data = _decodeJsonObject(response.body);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() {
          _quiz = GrammarQuizQuestion.fromJson(data);
          _isLoading = false;
        });
      } else if (_isAiQuotaLimitResponse(response)) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Daily AI generation limit reached.';
        });
        unawaited(_showAiQuotaBottomSheet(context));
      } else {
        setState(() {
          _errorMessage =
              'Grammar quiz generation failed with status ${response.statusCode}.';
          _isLoading = false;
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Grammar quiz generation timed out. Please try again.';
        _isLoading = false;
      });
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Cannot reach the grammar generator. Make sure the backend is running.';
        _isLoading = false;
      });
    } on AiQuotaExceededException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Daily AI generation limit reached.';
        _isLoading = false;
      });
      unawaited(_showAiQuotaBottomSheet(context));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to generate a grammar quiz right now.';
        _isLoading = false;
      });
    }
  }

  void _selectOption(int index) {
    if (_selectedIndex != null) return;
    final isCorrect = index == _quiz?.correctIndex;
    unawaited(_playGrammarAnswerHaptic(isCorrect));
    setState(() {
      _selectedIndex = index;
    });
  }

  Future<void> _saveToLedger() async {
    final quiz = _quiz;
    if (quiz == null) return;

    setState(() {
      _isSaving = true;
    });

    try {
      await _authenticatedPost(
        _ledgerEndpoint,
        body: jsonEncode({
          'error_type': quiz.concept,
          'original_sentence': quiz.question,
          'user_answer':
              _selectedIndex == null ? null : quiz.options[_selectedIndex!],
          'corrected_sentence': quiz.options[quiz.correctIndex],
          'explanation': quiz.explanation,
        }),
      ).timeout(const Duration(seconds: 10));

      if (!mounted) return;
      setState(() {
        _isSaved = true;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Saved to your Grammar Error Ledger'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
                'Could not save yet. Try again after the backend is running.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }
}

class GrammarQuizQuestion {
  const GrammarQuizQuestion({
    required this.concept,
    required this.question,
    required this.options,
    required this.correctIndex,
    required this.explanation,
    required this.metrics,
  });

  final String concept;
  final String question;
  final List<String> options;
  final int correctIndex;
  final String explanation;
  final PerformanceMetrics? metrics;

  factory GrammarQuizQuestion.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    final options = rawOptions is List
        ? rawOptions.map((option) => option.toString()).toList()
        : const [
            'She has studied English for three years.',
            'She studied English since three years.',
            'She studies English from three years.',
            'She is study English for three years.',
          ];
    final safeOptions =
        options.length >= 4 ? options.take(4).toList() : options;
    while (safeOptions.length < 4) {
      safeOptions.add('Option ${safeOptions.length + 1}');
    }

    final correctIndex = PerformanceMetrics._asInt(
      json['correct_option_index'] ?? json['correct_index'],
    );

    return GrammarQuizQuestion(
      concept: _stringFromJson(
        json,
        ['concept', 'error_type'],
        fallback: 'grammar_quiz',
      ),
      question: _stringFromJson(
        json,
        ['question', 'prompt'],
        fallback: 'Choose the grammatically correct sentence.',
      ),
      options: safeOptions,
      correctIndex: correctIndex >= 0 && correctIndex < safeOptions.length
          ? correctIndex
          : 0,
      explanation: _stringFromJson(
        json,
        ['explanation', 'correction'],
        fallback:
            'The correct answer follows standard English grammar and is the best choice in context.',
      ),
      metrics: PerformanceMetrics.maybeFromResponse(json),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'concept': concept,
      'question': question,
      'options': options,
      'correct_option_index': correctIndex,
      'explanation': explanation,
      if (metrics != null)
        'performance_metrics': {
          'total_time_seconds': metrics!.totalTimeSeconds,
          'tokens_per_second': metrics!.tokensPerSecond,
          'total_tokens': metrics!.totalTokens,
        },
    };
  }
}

Future<void> _playGrammarAnswerHaptic(bool isCorrect) async {
  if (isCorrect) {
    await HapticFeedback.mediumImpact();
    return;
  }

  await HapticFeedback.vibrate();
  await Future<void>.delayed(const Duration(milliseconds: 90));
  await HapticFeedback.heavyImpact();
}

class _GrammarQuestionCard extends StatelessWidget {
  const _GrammarQuestionCard({
    required this.quiz,
    required this.selectedIndex,
    required this.onSelect,
  });

  final GrammarQuizQuestion quiz;
  final int? selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFF101828),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.psychology_alt_rounded,
                    color: Color(0xFF36F3A5),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'AI Grammar Drill',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              quiz.question,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    height: 1.25,
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 16),
            for (var index = 0; index < quiz.options.length; index++) ...[
              _QuizOptionTile(
                label: String.fromCharCode(65 + index),
                text: quiz.options[index],
                state: _optionState(index),
                onTap: () => onSelect(index),
              ),
              if (index != quiz.options.length - 1) const SizedBox(height: 10),
            ],
            if (quiz.metrics != null) ...[
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: InferenceBadge(
                  totalTimeSeconds: quiz.metrics!.totalTimeSeconds,
                  tokensPerSecond: quiz.metrics!.tokensPerSecond,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  _QuizOptionState _optionState(int index) {
    if (selectedIndex == null) return _QuizOptionState.idle;
    if (index == quiz.correctIndex) return _QuizOptionState.correct;
    if (index == selectedIndex) return _QuizOptionState.wrong;
    return _QuizOptionState.dimmed;
  }
}

enum _QuizOptionState { idle, correct, wrong, dimmed }

class _QuizOptionTile extends StatelessWidget {
  const _QuizOptionTile({
    required this.label,
    required this.text,
    required this.state,
    required this.onTap,
  });

  final String label;
  final String text;
  final _QuizOptionState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = switch (state) {
      _QuizOptionState.correct => (
          background: kNeonGreen.withOpacity(0.14),
          border: kNeonGreen,
          foreground: kNeonGreen,
          icon: Icons.check_circle_rounded,
        ),
      _QuizOptionState.wrong => (
          background: kDangerRed.withOpacity(0.14),
          border: kDangerRed,
          foreground: kDangerRed,
          icon: Icons.cancel_rounded,
        ),
      _QuizOptionState.dimmed => (
          background: kSurfaceGlass,
          border: kGlassBorder,
          foreground: kTextTertiary,
          icon: Icons.circle_outlined,
        ),
      _ => (
          background: kSurfaceGlassStrong,
          border: kGlassBorder,
          foreground: kTextPrimary,
          icon: Icons.circle_outlined,
        ),
    };

    return InkWell(
      onTap: state == _QuizOptionState.idle ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.border, width: 1.4),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 17,
              backgroundColor: colors.foreground.withOpacity(0.1),
              child: Text(
                label,
                style: TextStyle(
                  color: colors.foreground,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: colors.foreground,
                  fontWeight: FontWeight.w800,
                  height: 1.35,
                ),
              ),
            ),
            Icon(colors.icon, color: colors.foreground),
          ],
        ),
      ),
    );
  }
}

class _GrammarExplanationCard extends StatelessWidget {
  const _GrammarExplanationCard({super.key, required this.explanation});

  final String explanation;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: ExpansionTile(
        initiallyExpanded: true,
        leading: const Icon(Icons.lightbulb_outline_rounded),
        title: const Text(
          'Explanation',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text(
            explanation,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: kTextSecondary,
                  height: 1.45,
                ),
          ),
        ],
      ),
    );
  }
}

class _QuizHintCard extends StatelessWidget {
  const _QuizHintCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Row(
        children: [
          const Icon(Icons.touch_app_rounded, color: Color(0xFF2563EB)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Pick one answer to unlock the explanation.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF1D4ED8),
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowingQuizLoader extends StatefulWidget {
  const _GlowingQuizLoader();

  @override
  State<_GlowingQuizLoader> createState() => _GlowingQuizLoaderState();
}

class _GlowingQuizLoaderState extends State<_GlowingQuizLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _controller.stop();
    return const GrammarSkeleton();
  }
}

class _QuizErrorState extends StatelessWidget {
  const _QuizErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return UnifiedErrorState(
      message: message,
      onRetry: onRetry,
    );
  }
}

class TimeAttackSimulatorScreen extends ConsumerStatefulWidget {
  const TimeAttackSimulatorScreen({super.key});

  @override
  ConsumerState<TimeAttackSimulatorScreen> createState() =>
      _TimeAttackSimulatorScreenState();
}

class _TimeAttackSimulatorScreenState
    extends ConsumerState<TimeAttackSimulatorScreen>
    with SingleTickerProviderStateMixin {
  static const String _cachedExamKey = 'cached_full_mock_exam_v1';
  static final Uri _fullMockExamEndpoint =
      AppConfig.apiUri('/generate/full-mock-exam/jobs');
  static final Uri _evaluateMockExamEndpoint =
      AppConfig.apiUri('/evaluate/full-mock-exam');

  late final AnimationController _pulseController;
  final PageController _pageController = PageController();
  final TextEditingController _essayController = TextEditingController();
  final TextEditingController _translationController = TextEditingController();
  Timer? _timer;

  TimeAttackExam? _exam;
  final Map<int, int> _selectedAnswers = <int, int>{};
  final Set<int> _flaggedQuestions = <int>{};
  Duration _remaining = const Duration(minutes: 100);
  bool _showWarning = true;
  bool _isLoading = false;
  bool _isGrading = false;
  bool _isSubmitted = false;
  bool _submissionWasAutomatic = false;
  int _pageIndex = 0;
  String? _loadMessage;
  String? _gradingError;

  bool get _isExamActive =>
      !_showWarning && !_isLoading && !_isGrading && !_isSubmitted;
  bool get _isCriticalTime => _remaining <= const Duration(minutes: 10);

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
      lowerBound: 0.92,
      upperBound: 1.08,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseController.dispose();
    _pageController.dispose();
    _essayController.dispose();
    _translationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (!_isExamActive) return true;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Exam is in progress. Submit before exiting.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        return false;
      },
      child: Scaffold(
        appBar: _showWarning
            ? null
            : AppBar(
                automaticallyImplyLeading: !_isExamActive,
                title: const Text('Time-Attack GSAT Simulator'),
              ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_showWarning) {
      return _TimeAttackWarningScreen(onStart: _startExam);
    }

    if (_isLoading) {
      return AppPage(
        children: [
          const Hero(
            tag: 'time-attack-simulator-flow',
            child: Material(
              color: Colors.transparent,
              child: ReadingSkeleton(),
            ),
          ),
          const SizedBox(height: 16),
          const GrammarSkeleton(),
          if (_loadMessage != null) ...[
            const SizedBox(height: 16),
            _StatusBanner(
              message: _loadMessage!,
              icon: Icons.info_outline_rounded,
              color: kElectricBlue,
              backgroundColor: kElectricBlue,
            ),
          ],
        ],
      );
    }

    if (_isGrading) {
      return AppPage(
        children: const [
          ReadingSkeleton(),
          SizedBox(height: 16),
          GrammarSkeleton(),
          SizedBox(height: 16),
          Center(
            child: Text(
              'Scoring all 56 questions, translation, and essay...',
              style: TextStyle(color: kTextSecondary),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }

    if (_gradingError != null) {
      return AppPage(
        children: [
          UnifiedErrorState(
            title: 'Scoring was interrupted',
            message: _gradingError!,
            onRetry: () => _finishExam(
              autoSubmitted: _submissionWasAutomatic,
            ),
          ),
        ],
      );
    }

    final exam = _exam;
    if (exam == null) {
      return AppPage(
        children: [
          _QuizErrorState(
            message: 'Unable to prepare the simulator.',
            onRetry: _startExam,
          ),
        ],
      );
    }

    final isTablet = isTabletLayout(context);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(-0.7, -1),
          radius: 1.2,
          colors: [Color(0x262F80ED), kAppBackground],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
              child: _TimeAttackTimerBar(
                remaining: _remaining,
                isCritical: _isCriticalTime,
                pulseAnimation: _pulseController,
                sectionLabel: _sectionLabel(_pageIndex),
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  if (isTablet)
                    _TimeAttackQuestionSidebar(
                      exam: exam,
                      selectedAnswers: _selectedAnswers,
                      flaggedQuestions: _flaggedQuestions,
                      onJumpToSection: _jumpToPage,
                    ),
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      onPageChanged: (index) =>
                          setState(() => _pageIndex = index),
                      children: [
                        for (final section in exam.sections)
                          _TimeAttackSectionPage(
                            section: section,
                            selectedAnswers: _selectedAnswers,
                            flaggedQuestions: _flaggedQuestions,
                            isLocked: _isSubmitted,
                            onSelect: _selectAnswer,
                            onToggleFlag: _toggleQuestionFlag,
                          ),
                        _TimeAttackEssaySection(
                          prompt: exam.essayPrompt,
                          translationPrompt: exam.translationPrompt,
                          essayController: _essayController,
                          translationController: _translationController,
                          isLocked: _isSubmitted,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (!isTablet)
              _TimeAttackQuestionStrip(
                exam: exam,
                selectedAnswers: _selectedAnswers,
                flaggedQuestions: _flaggedQuestions,
                onJumpToSection: _jumpToPage,
              ),
            _TimeAttackBottomBar(
              pageIndex: _pageIndex,
              onPrevious:
                  _pageIndex == 0 ? null : () => _jumpToPage(_pageIndex - 1),
              onNext: _pageIndex == exam.pageCount - 1
                  ? null
                  : () => _jumpToPage(_pageIndex + 1),
              onSubmit: _submitExam,
              isSubmitted: _isSubmitted,
              pageCount: exam.pageCount,
              answeredCount: _selectedAnswers.length,
              flaggedCount: _flaggedQuestions.length,
              totalQuestions: exam.choiceQuestionCount,
              onNavigate: isTablet ? null : () => _showQuestionNavigator(exam),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startExam() async {
    setState(() {
      _showWarning = false;
      _isLoading = true;
      _isSubmitted = false;
      _submissionWasAutomatic = false;
      _gradingError = null;
      _remaining = const Duration(minutes: 100);
      _selectedAnswers.clear();
      _flaggedQuestions.clear();
      _essayController.clear();
      _translationController.clear();
      _loadMessage = 'Generating a full GSAT-style mock exam set...';
    });

    try {
      final exam =
          await _fetchExamBundle().timeout(const Duration(seconds: 100));
      if (!mounted) return;
      setState(() {
        _exam = exam;
        _isLoading = false;
        _loadMessage = null;
      });
      await _cacheExam(exam);
      _startTimer();
    } on AiQuotaExceededException {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _showWarning = true;
        _loadMessage = null;
      });
      unawaited(_showAiQuotaBottomSheet(context));
    } catch (_) {
      final cachedExam = await _loadCachedExam();
      if (!mounted) return;
      setState(() {
        _exam = cachedExam;
        _isLoading = false;
        _loadMessage = cachedExam == null
            ? 'No verified exam is available. Connect to the backend and retry.'
            : 'Backend unavailable. Starting from your cached simulator pack.';
      });
      if (cachedExam != null) _startTimer();
    }
  }

  Future<TimeAttackExam> _fetchExamBundle() async {
    final response = await _authenticatedPost(
      _fullMockExamEndpoint,
      body: jsonEncode({
        'difficulty': 'GSAT',
        'version':
            'time-attack-${DateTime.now().toUtc().toIso8601String().substring(0, 10)}',
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      _throwIfAiQuotaExceeded(response);
      throw StateError('Full mock exam generation failed.');
    }

    final completedJob = await const BackgroundJobPoller().waitForCompletion(
      initialJob: _decodeJsonObject(response.body),
      onStatus: (status) {
        if (!mounted) return;
        setState(() {
          _loadMessage = status == 'running'
              ? 'Building and validating all 56 GSAT questions...'
              : 'Your exam is queued. Preparing the generation worker...';
        });
      },
      fetch: (jobId) async {
        final poll = await _authenticatedGet(AppConfig.apiUri('/jobs/$jobId'));
        if (poll.statusCode < 200 || poll.statusCode >= 300) {
          throw StateError('Mock exam job polling failed.');
        }
        return _decodeJsonObject(poll.body);
      },
    );
    final result = completedJob['result'];
    if (result is! Map) {
      throw const FormatException('Completed mock exam job has no result.');
    }
    return TimeAttackExam.fromJson(Map<String, dynamic>.from(result));
  }

  Future<void> _cacheExam(TimeAttackExam exam) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cachedExamKey, jsonEncode(exam.toJson()));
    } catch (_) {
      // Simulator caching should never block the timed flow.
    }
  }

  Future<TimeAttackExam?> _loadCachedExam() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cachedExamKey);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final exam = TimeAttackExam.fromJson(Map<String, dynamic>.from(decoded));
      if (exam.examId.trim().isEmpty || exam.examId == 'offline-ungradable') {
        return null;
      }
      return exam;
    } catch (_) {
      return null;
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _isSubmitted) return;
      if (_remaining <= Duration.zero) {
        _autoSubmitExam();
        return;
      }

      setState(() {
        _remaining -= const Duration(seconds: 1);
      });

      if (_remaining <= Duration.zero) {
        _autoSubmitExam();
        return;
      }

      if (_isCriticalTime && !_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    });
  }

  void _selectAnswer(int questionNumber, int optionIndex) {
    if (_isSubmitted) return;
    setState(() {
      _selectedAnswers[questionNumber] = optionIndex;
    });
    unawaited(HapticFeedback.selectionClick());
  }

  void _toggleQuestionFlag(int questionNumber) {
    if (_isSubmitted) return;
    setState(() {
      if (!_flaggedQuestions.add(questionNumber)) {
        _flaggedQuestions.remove(questionNumber);
      }
    });
    unawaited(HapticFeedback.selectionClick());
  }

  void _jumpToPage(int index) {
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _autoSubmitExam() async {
    if (_isSubmitted) return;
    await HapticFeedback.vibrate();
    await _finishExam(autoSubmitted: true);
  }

  Future<void> _submitExam() async {
    if (_isSubmitted) return;
    await HapticFeedback.heavyImpact();
    await _finishExam(autoSubmitted: false);
  }

  Future<void> _finishExam({required bool autoSubmitted}) async {
    final exam = _exam;
    if (exam == null || _isGrading || (_isSubmitted && _gradingError == null)) {
      return;
    }

    _timer?.cancel();
    _pulseController.stop();
    setState(() {
      _isSubmitted = true;
      _isGrading = true;
      _submissionWasAutomatic = autoSubmitted;
      _gradingError = null;
    });
    final timeUsed = const Duration(minutes: 100) - _remaining;

    try {
      final response = await _authenticatedPost(
        _evaluateMockExamEndpoint,
        body: jsonEncode({
          'exam_id': exam.examId,
          'selected_answers': _selectedAnswers.map(
            (number, answer) => MapEntry(number.toString(), answer),
          ),
          'translation_answer': _translationController.text,
          'essay_answer': _essayController.text,
          'app_mode': _currentAppModeApiValue,
        }),
      ).timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _throwIfAiQuotaExceeded(response);
        throw StateError('Mock exam grading returned ${response.statusCode}.');
      }
      final result = TimeAttackResult.fromJson(
        _decodeJsonObject(response.body),
        autoSubmitted: autoSubmitted,
        timeUsed: timeUsed,
        essayWordCount: _essayController.text
            .trim()
            .split(RegExp(r'\s+'))
            .where((word) => word.isNotEmpty)
            .length,
      );
      if (!mounted) return;
      ref.read(rewardVFXControllerProvider).trigger('full mock exam submitted');
      context.go('/exam-simulator/results', extra: result);
    } on AiQuotaExceededException {
      if (!mounted) return;
      setState(() {
        _isGrading = false;
        _gradingError =
            'Your answers are locked, but today\'s AI quota is exhausted. Retry after the quota resets.';
      });
      unawaited(_showAiQuotaBottomSheet(context));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isGrading = false;
        _gradingError =
            'Your answers are safely locked. Reconnect to the backend and retry authoritative grading.';
      });
    }
  }

  String _sectionLabel(int index) {
    final exam = _exam;
    if (exam == null) return 'Full Mock Exam';
    if (index >= 0 && index < exam.sections.length) {
      return exam.sections[index].subtitle;
    }
    return 'Translation & Essay';
  }

  Future<void> _showQuestionNavigator(TimeAttackExam exam) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: CleanCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Question Navigator',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final section in exam.sections)
                          for (final question in section.questions)
                            Builder(
                              builder: (context) {
                                final isAnswered = _selectedAnswers
                                    .containsKey(question.number);
                                final isFlagged =
                                    _flaggedQuestions.contains(question.number);
                                return InkWell(
                                  borderRadius: BorderRadius.circular(999),
                                  onTap: () {
                                    Navigator.of(context).pop();
                                    _jumpToPage(exam.sections.indexOf(section));
                                  },
                                  child: Container(
                                    width: 42,
                                    height: 36,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: isFlagged
                                          ? const Color(0xFFFFC857)
                                              .withOpacity(0.16)
                                          : isAnswered
                                              ? kNeonGreen.withOpacity(0.16)
                                              : kSurfaceGlassStrong,
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: isFlagged
                                            ? const Color(0xFFFFC857)
                                            : isAnswered
                                                ? kNeonGreen
                                                : kGlassBorder,
                                      ),
                                    ),
                                    child: Text(
                                      question.number.toString(),
                                      style: TextStyle(
                                        color: isFlagged
                                            ? const Color(0xFFFFC857)
                                            : isAnswered
                                                ? kNeonGreen
                                                : kTextSecondary,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '${_selectedAnswers.length}/${exam.choiceQuestionCount} answered · ${_flaggedQuestions.length} flagged',
                      style: const TextStyle(color: kTextTertiary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class TimeAttackExam {
  const TimeAttackExam({
    required this.examId,
    required this.title,
    required this.sections,
    required this.essayPrompt,
    required this.translationPrompt,
  });

  final String examId;
  final String title;
  final List<TimeAttackSection> sections;
  final String essayPrompt;
  final String translationPrompt;

  int get pageCount => sections.length + 1;
  int get choiceQuestionCount =>
      sections.fold(0, (total, section) => total + section.questions.length);
  List<TimeAttackQuestion> get choiceQuestions =>
      [for (final section in sections) ...section.questions];

  Map<String, dynamic> toJson() {
    return {
      'exam_id': examId,
      'title': title,
      'sections': sections.map((section) => section.toJson()).toList(),
      'essay_prompt': essayPrompt,
      'translation_prompt': translationPrompt,
    };
  }

  factory TimeAttackExam.fromJson(Map<String, dynamic> json) {
    final rawSections = json['sections'];
    final sections = rawSections is List
        ? rawSections
            .whereType<Map>()
            .map((item) =>
                TimeAttackSection.fromJson(Map<String, dynamic>.from(item)))
            .where((section) => section.questions.isNotEmpty)
            .toList()
        : <TimeAttackSection>[];
    if (sections.length < 6) {
      throw const FormatException('Full mock exam must contain six sections.');
    }

    final nonChoice = json['non_choice'] is Map
        ? Map<String, dynamic>.from(json['non_choice'] as Map)
        : <String, dynamic>{};
    final translation = nonChoice['translation'] is Map
        ? Map<String, dynamic>.from(nonChoice['translation'] as Map)
        : <String, dynamic>{};
    final essay = nonChoice['essay'] is Map
        ? Map<String, dynamic>.from(nonChoice['essay'] as Map)
        : <String, dynamic>{};

    return TimeAttackExam(
      examId: _stringFromJson(json, ['exam_id'], fallback: ''),
      title: _stringFromJson(json, ['title'],
          fallback: 'GSAT English Full Mock Exam'),
      sections: sections,
      essayPrompt: _stringFromJson(
        essay,
        ['prompt', 'essay_prompt'],
        fallback: randomEssayPrompt(),
      ),
      translationPrompt:
          '${_stringFromJson(translation, ['zh_to_en'], fallback: '穩定的練習能幫助學生更有自信。')}\n\n${_stringFromJson(translation, [
                'en_to_zh'
              ], fallback: 'Careful review helps students improve faster.')}',
    );
  }

  factory TimeAttackExam.mock() {
    final fallbackSections = <TimeAttackSection>[];
    final titles = [
      ('Vocabulary', 'Questions 1-10', 1, 10),
      ('Cloze Test (克漏字)', 'Questions 11-20', 11, 20),
      ('Passage Completion (文意選填)', 'Questions 21-30', 21, 30),
      ('Discourse Structure (篇章結構)', 'Questions 31-34', 31, 34),
      ('Reading Comprehension (閱讀測驗)', 'Questions 35-46', 35, 46),
      ('Mixed Question Types (混合題)', 'Questions 47-56', 47, 56),
    ];
    for (final spec in titles) {
      fallbackSections.add(
        TimeAttackSection(
          title: spec.$1,
          subtitle: spec.$2,
          instructions: 'Choose the best answer.',
          passage: spec.$3 >= 11
              ? 'A student improves through repeated practice, careful review, and attention to meaning in context.'
              : null,
          questions: [
            for (var number = spec.$3; number <= spec.$4; number++)
              TimeAttackQuestion(
                number: number,
                type: spec.$1,
                stem: 'Question $number: Choose the best GSAT-style answer.',
                options: const [
                  'The option that best fits the meaning and grammar.',
                  'A tempting but incorrect distractor.',
                  'An option with unnatural English.',
                  'An option that changes the meaning.',
                ],
                correctIndex: 0,
                explanation:
                    'Eliminate distractors by grammar, meaning, and context.',
              ),
          ],
        ),
      );
    }
    return TimeAttackExam(
      examId: 'offline-ungradable',
      title: 'GSAT English Full Mock Exam',
      sections: fallbackSections,
      essayPrompt: randomEssayPrompt(),
      translationPrompt:
          '穩定的練習能幫助學生在考試中更有自信。\n\nStudents who review their mistakes carefully often improve faster.',
    );
  }

  static String randomEssayPrompt() {
    final prompts = [
      'Some students believe AI tools make learning more effective, while others worry that students may depend on them too much. Write an essay explaining your opinion with reasons and examples.',
      'Many schools are considering later start times for teenagers. Do you agree or disagree with this policy? Explain your answer with examples.',
      'Describe one habit that has helped you improve as a learner. Explain why it works and how other students could apply it.',
    ];
    return prompts[DateTime.now().millisecondsSinceEpoch % prompts.length];
  }
}

class TimeAttackSection {
  const TimeAttackSection({
    required this.title,
    required this.subtitle,
    required this.instructions,
    required this.questions,
    this.passage,
  });

  final String title;
  final String subtitle;
  final String instructions;
  final String? passage;
  final List<TimeAttackQuestion> questions;

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'subtitle': subtitle,
      'instructions': instructions,
      if (passage != null) 'passage': passage,
      'questions': questions.map((question) => question.toJson()).toList(),
    };
  }

  factory TimeAttackSection.fromJson(Map<String, dynamic> json) {
    final rawQuestions = json['questions'];
    final questions = rawQuestions is List
        ? rawQuestions
            .whereType<Map>()
            .map((item) =>
                TimeAttackQuestion.fromJson(Map<String, dynamic>.from(item)))
            .where((question) => question.options.length >= 2)
            .toList()
        : <TimeAttackQuestion>[];
    final rawPassages = json['passages'];
    final passageFromList = rawPassages is List
        ? rawPassages
            .whereType<Map>()
            .map((item) => _stringFromJson(
                Map<String, dynamic>.from(item), ['text', 'passage'],
                fallback: ''))
            .where((text) => text.trim().isNotEmpty)
            .join('\n\n')
        : '';
    return TimeAttackSection(
      title: _stringFromJson(json, ['title'], fallback: 'Exam Section'),
      subtitle: _stringFromJson(json, ['subtitle'], fallback: 'Questions'),
      instructions: _stringFromJson(
        json,
        ['instructions', 'direction'],
        fallback: 'Choose the best answer.',
      ),
      passage:
          _nullableString(json['passage']) ?? _nullableString(passageFromList),
      questions: questions,
    );
  }
}

class TimeAttackQuestion {
  const TimeAttackQuestion({
    required this.number,
    required this.type,
    required this.stem,
    required this.options,
    required this.correctIndex,
    required this.explanation,
  });

  final int number;
  final String type;
  final String stem;
  final List<String> options;
  final int correctIndex;
  final String explanation;

  Map<String, dynamic> toJson() {
    return {
      'number': number,
      'type': type,
      'stem': stem,
      'options': options,
      if (correctIndex >= 0) 'correct_option_index': correctIndex,
      if (explanation.isNotEmpty) 'explanation': explanation,
    };
  }

  factory TimeAttackQuestion.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    final options = rawOptions is List
        ? rawOptions
            .map((option) => option.toString())
            .where((text) => text.trim().isNotEmpty)
            .toList()
        : <String>[];
    var correctIndex = json.containsKey('correct_option_index')
        ? PerformanceMetrics._asInt(json['correct_option_index'])
        : -1;
    if (correctIndex < 0 || correctIndex >= options.length) correctIndex = -1;
    return TimeAttackQuestion(
      number: PerformanceMetrics._asInt(json['number']),
      type: _stringFromJson(json, ['type'], fallback: 'question'),
      stem: _stringFromJson(json, ['stem', 'question'],
          fallback: 'Choose the best answer.'),
      options: options,
      correctIndex: correctIndex,
      explanation: _stringFromJson(json, ['explanation'], fallback: ''),
    );
  }
}

class TimeAttackResult {
  const TimeAttackResult({
    required this.totalScore,
    required this.objectiveCorrect,
    required this.objectiveTotal,
    required this.essayWordCount,
    required this.objectiveScore,
    required this.translationScore,
    required this.essayScore,
    required this.feedback,
    required this.autoSubmitted,
    required this.timeUsed,
    required this.metrics,
  });

  final double totalScore;
  final int objectiveCorrect;
  final int objectiveTotal;
  final int essayWordCount;
  final double objectiveScore;
  final double translationScore;
  final double essayScore;
  final String feedback;
  final bool autoSubmitted;
  final Duration timeUsed;
  final PerformanceMetrics? metrics;

  factory TimeAttackResult.fromJson(
    Map<String, dynamic> json, {
    required bool autoSubmitted,
    required Duration timeUsed,
    required int essayWordCount,
  }) {
    return TimeAttackResult(
      totalScore: PerformanceMetrics._asDouble(json['total_score']),
      objectiveCorrect: PerformanceMetrics._asInt(json['objective_correct']),
      objectiveTotal: PerformanceMetrics._asInt(json['objective_total']),
      essayWordCount: essayWordCount,
      objectiveScore: PerformanceMetrics._asDouble(json['objective_score']),
      translationScore: PerformanceMetrics._asDouble(json['translation_score']),
      essayScore: PerformanceMetrics._asDouble(json['essay_score']),
      autoSubmitted: autoSubmitted,
      timeUsed: timeUsed,
      feedback: _stringFromAny(
        json['feedback'],
        fallback:
            'The exam was graded using the official stored answer key and GSAT rubric.',
      ),
      metrics: PerformanceMetrics.maybeFromResponse(json),
    );
  }
}

class _TimeAttackWarningScreen extends StatelessWidget {
  const _TimeAttackWarningScreen({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.8),
          radius: 1.2,
          colors: [Color(0x332F80ED), kAppBackground],
        ),
      ),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Hero(
              tag: 'time-attack-simulator-flow',
              child: Material(
                color: Colors.transparent,
                child: CleanCard(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 78,
                          height: 78,
                          decoration: BoxDecoration(
                            color: kDangerRed.withOpacity(0.12),
                            shape: BoxShape.circle,
                            border: Border.all(color: kDangerRed),
                          ),
                          child: const Icon(
                            Icons.timer_outlined,
                            color: kDangerRed,
                            size: 42,
                          ),
                        ),
                        const SizedBox(height: 22),
                        Text(
                          'This simulates the 100-minute GSAT. Do not exit.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w900,
                                height: 1.18,
                              ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'You will complete Vocabulary, Cloze, Passage Completion, Discourse Structure, Reading, Mixed Questions, and Translation & Essay. When the timer hits 00:00, the exam auto-submits.',
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: kTextSecondary,
                                    height: 1.45,
                                  ),
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: onStart,
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('Begin 100:00 Simulator'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TimeAttackTimerBar extends StatelessWidget {
  const _TimeAttackTimerBar({
    required this.remaining,
    required this.isCritical,
    required this.pulseAnimation,
    required this.sectionLabel,
  });

  final Duration remaining;
  final bool isCritical;
  final Animation<double> pulseAnimation;
  final String sectionLabel;

  @override
  Widget build(BuildContext context) {
    const criticalColor = Color(0xFFFF375F);
    final timerChip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: isCritical
            ? criticalColor.withOpacity(0.16)
            : kNeonGreen.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: isCritical ? criticalColor : kNeonGreen),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.timer_outlined,
            color: isCritical ? criticalColor : kNeonGreen,
            size: 18,
          ),
          const SizedBox(width: 6),
          Text(
            _formatDuration(remaining),
            style: TextStyle(
              color: isCritical ? criticalColor : kNeonGreen,
              fontWeight: FontWeight.w900,
              fontSize: 18,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );

    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                sectionLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            isCritical
                ? ScaleTransition(scale: pulseAnimation, child: timerChip)
                : timerChip,
          ],
        ),
      ),
    );
  }
}

class _TimeAttackReadingSection extends StatelessWidget {
  const _TimeAttackReadingSection({required this.article});

  final String article;

  @override
  Widget build(BuildContext context) {
    final scale = tabletReadingTextScale(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
      children: [
        CleanCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Reading Passage',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'Read for main idea, transitions, and inference. You can move to grammar whenever ready.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: kTextTertiary,
                        height: 1.4,
                      ),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: PassageAudioButton(
                    text: article,
                    label: 'Play Passage',
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  article,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: kTextSecondary,
                        height: 1.55,
                        fontSize:
                            (Theme.of(context).textTheme.bodyLarge?.fontSize ??
                                    16) *
                                scale,
                      ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TimeAttackSectionPage extends StatelessWidget {
  const _TimeAttackSectionPage({
    required this.section,
    required this.selectedAnswers,
    required this.flaggedQuestions,
    required this.isLocked,
    required this.onSelect,
    required this.onToggleFlag,
  });

  final TimeAttackSection section;
  final Map<int, int> selectedAnswers;
  final Set<int> flaggedQuestions;
  final bool isLocked;
  final void Function(int questionNumber, int optionIndex) onSelect;
  final ValueChanged<int> onToggleFlag;

  @override
  Widget build(BuildContext context) {
    final scale = tabletReadingTextScale(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
      children: [
        CleanCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(section.title,
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  section.subtitle,
                  style: const TextStyle(
                    color: kNeonGreen,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  section.instructions,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: kTextTertiary,
                        height: 1.4,
                      ),
                ),
                if (section.passage != null) ...[
                  const SizedBox(height: 14),
                  Align(
                    alignment: Alignment.centerRight,
                    child: PassageAudioButton(
                      text: section.passage!,
                      label: 'Play Text',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    section.passage!,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: kTextSecondary,
                          height: 1.55,
                          fontSize: (Theme.of(context)
                                      .textTheme
                                      .bodyLarge
                                      ?.fontSize ??
                                  16) *
                              scale,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        for (final question in section.questions) ...[
          CleanCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Question ${question.number} · ${question.type}',
                          style:
                              Theme.of(context).textTheme.labelLarge?.copyWith(
                                    color: kNeonGreen,
                                    fontWeight: FontWeight.w900,
                                  ),
                        ),
                      ),
                      IconButton(
                        onPressed: isLocked
                            ? null
                            : () => onToggleFlag(question.number),
                        tooltip: flaggedQuestions.contains(question.number)
                            ? 'Remove review flag'
                            : 'Flag for review',
                        icon: Icon(
                          flaggedQuestions.contains(question.number)
                              ? Icons.flag_rounded
                              : Icons.outlined_flag_rounded,
                          color: flaggedQuestions.contains(question.number)
                              ? const Color(0xFFFFC857)
                              : kTextTertiary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    question.stem,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          height: 1.35,
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  const SizedBox(height: 12),
                  for (var optionIndex = 0;
                      optionIndex < question.options.length;
                      optionIndex++) ...[
                    _TimeAttackOptionTile(
                      label: String.fromCharCode(65 + optionIndex),
                      text: question.options[optionIndex],
                      isSelected:
                          selectedAnswers[question.number] == optionIndex,
                      isLocked: isLocked,
                      onTap: () => onSelect(question.number, optionIndex),
                    ),
                    if (optionIndex != question.options.length - 1)
                      const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}

class _TimeAttackGrammarSection extends StatelessWidget {
  const _TimeAttackGrammarSection({
    required this.questions,
    required this.selectedAnswers,
    required this.isLocked,
    required this.onSelect,
  });

  final List<GrammarQuizQuestion> questions;
  final List<int?> selectedAnswers;
  final bool isLocked;
  final void Function(int questionIndex, int optionIndex) onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
      children: [
        for (var questionIndex = 0;
            questionIndex < questions.length;
            questionIndex++) ...[
          CleanCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Question ${questionIndex + 1}',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: kNeonGreen,
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    questions[questionIndex].question,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          height: 1.35,
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  const SizedBox(height: 12),
                  for (var optionIndex = 0;
                      optionIndex < questions[questionIndex].options.length;
                      optionIndex++) ...[
                    _TimeAttackOptionTile(
                      label: String.fromCharCode(65 + optionIndex),
                      text: questions[questionIndex].options[optionIndex],
                      isSelected: selectedAnswers[questionIndex] == optionIndex,
                      isLocked: isLocked,
                      onTap: () => onSelect(questionIndex, optionIndex),
                    ),
                    if (optionIndex !=
                        questions[questionIndex].options.length - 1)
                      const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
          if (questionIndex != questions.length - 1) const SizedBox(height: 14),
        ],
      ],
    );
  }
}

class _TimeAttackOptionTile extends StatelessWidget {
  const _TimeAttackOptionTile({
    required this.label,
    required this.text,
    required this.isSelected,
    required this.isLocked,
    required this.onTap,
  });

  final String label;
  final String text;
  final bool isSelected;
  final bool isLocked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: isLocked ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 170),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? kElectricBlue.withOpacity(0.16)
              : kSurfaceGlassStrong,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isSelected ? kElectricBlue : kGlassBorder),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor:
                  isSelected ? kElectricBlue.withOpacity(0.18) : kSurfaceGlass,
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? kElectricBlue : kTextSecondary,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: isSelected ? kTextPrimary : kTextSecondary,
                      fontWeight: FontWeight.w800,
                      height: 1.35,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeAttackEssaySection extends StatelessWidget {
  const _TimeAttackEssaySection({
    required this.prompt,
    required this.translationPrompt,
    required this.essayController,
    required this.translationController,
    required this.isLocked,
  });

  final String prompt;
  final String translationPrompt;
  final TextEditingController essayController;
  final TextEditingController translationController;
  final bool isLocked;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
      children: [
        CleanCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Translation & Essay',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: kNeonGreen.withOpacity(0.09),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kNeonGreen.withOpacity(0.34)),
                  ),
                  child: Text(
                    translationPrompt,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: kTextSecondary,
                          fontWeight: FontWeight.w800,
                          height: 1.45,
                        ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: translationController,
                  enabled: !isLocked,
                  minLines: 4,
                  maxLines: 7,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    labelText: 'Translation answer',
                    hintText: 'Write your translation response here...',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: kElectricBlue.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kElectricBlue.withOpacity(0.44)),
                  ),
                  child: Text(
                    prompt,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: kTextPrimary,
                          fontWeight: FontWeight.w800,
                          height: 1.45,
                        ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: essayController,
                  enabled: !isLocked,
                  minLines: 13,
                  maxLines: 18,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    hintText: 'Write your timed GSAT essay here...',
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TimeAttackQuestionStrip extends StatelessWidget {
  const _TimeAttackQuestionStrip({
    required this.exam,
    required this.selectedAnswers,
    required this.flaggedQuestions,
    required this.onJumpToSection,
  });

  final TimeAttackExam exam;
  final Map<int, int> selectedAnswers;
  final Set<int> flaggedQuestions;
  final ValueChanged<int> onJumpToSection;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kAppBackground.withOpacity(0.82),
        border: Border(top: BorderSide(color: kGlassBorder)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (var sectionIndex = 0;
              sectionIndex < exam.sections.length;
              sectionIndex++)
            for (final question in exam.sections[sectionIndex].questions) ...[
              _TimeAttackQuestionPill(
                number: question.number,
                isAnswered: selectedAnswers.containsKey(question.number),
                isFlagged: flaggedQuestions.contains(question.number),
                onTap: () => onJumpToSection(sectionIndex),
              ),
              const SizedBox(width: 6),
            ],
        ],
      ),
    );
  }
}

class _TimeAttackQuestionSidebar extends StatelessWidget {
  const _TimeAttackQuestionSidebar({
    required this.exam,
    required this.selectedAnswers,
    required this.flaggedQuestions,
    required this.onJumpToSection,
  });

  final TimeAttackExam exam;
  final Map<int, int> selectedAnswers;
  final Set<int> flaggedQuestions;
  final ValueChanged<int> onJumpToSection;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 124,
      margin: const EdgeInsets.fromLTRB(18, 0, 8, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kAppBackground.withOpacity(0.82),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kGlassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Questions',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: kTextPrimary,
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 7,
                runSpacing: 8,
                children: [
                  for (var sectionIndex = 0;
                      sectionIndex < exam.sections.length;
                      sectionIndex++)
                    for (final question
                        in exam.sections[sectionIndex].questions)
                      SizedBox(
                        width: 42,
                        height: 36,
                        child: _TimeAttackQuestionPill(
                          number: question.number,
                          isAnswered:
                              selectedAnswers.containsKey(question.number),
                          isFlagged: flaggedQuestions.contains(question.number),
                          onTap: () => onJumpToSection(sectionIndex),
                        ),
                      ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimeAttackQuestionPill extends StatelessWidget {
  const _TimeAttackQuestionPill({
    required this.number,
    required this.isAnswered,
    required this.isFlagged,
    required this.onTap,
  });

  final int number;
  final bool isAnswered;
  final bool isFlagged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isFlagged
        ? const Color(0xFFFFC857)
        : isAnswered
            ? kNeonGreen
            : kTextTertiary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withOpacity(isAnswered || isFlagged ? 0.16 : 0.07),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: color.withOpacity(isAnswered || isFlagged ? 0.9 : 0.35)),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Text(
              number.toString(),
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
            if (isFlagged)
              const Positioned(
                top: -8,
                right: -8,
                child: Icon(Icons.flag_rounded,
                    color: Color(0xFFFFC857), size: 12),
              ),
          ],
        ),
      ),
    );
  }
}

class _TimeAttackBottomBar extends StatelessWidget {
  const _TimeAttackBottomBar({
    required this.pageIndex,
    required this.pageCount,
    required this.answeredCount,
    required this.flaggedCount,
    required this.totalQuestions,
    required this.onPrevious,
    required this.onNext,
    required this.onSubmit,
    this.onNavigate,
    required this.isSubmitted,
  });

  final int pageIndex;
  final int pageCount;
  final int answeredCount;
  final int flaggedCount;
  final int totalQuestions;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onSubmit;
  final VoidCallback? onNavigate;
  final bool isSubmitted;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
        decoration: BoxDecoration(
          color: kAppBackground.withOpacity(0.92),
          border: Border(top: BorderSide(color: kGlassBorder)),
        ),
        child: Row(
          children: [
            IconButton.filledTonal(
              onPressed: onPrevious,
              icon: const Icon(Icons.chevron_left_rounded),
              tooltip: 'Previous section',
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var index = 0; index < pageCount; index++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: pageIndex == index ? 24 : 7,
                          height: 7,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color:
                                pageIndex == index ? kNeonGreen : kGlassBorder,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '$answeredCount/$totalQuestions answered · $flaggedCount flagged',
                    style: const TextStyle(
                      color: kTextTertiary,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            if (onNavigate != null) ...[
              const SizedBox(width: 10),
              IconButton.filledTonal(
                onPressed: onNavigate,
                icon: const Icon(Icons.grid_view_rounded),
                tooltip: 'Question navigator',
              ),
            ],
            const SizedBox(width: 10),
            if (pageIndex < pageCount - 1)
              IconButton.filled(
                onPressed: onNext,
                icon: const Icon(Icons.chevron_right_rounded),
                tooltip: 'Next section',
              )
            else
              FilledButton.icon(
                onPressed: isSubmitted ? null : onSubmit,
                icon: const Icon(Icons.send_rounded),
                label: const Text('Submit'),
              ),
          ],
        ),
      ),
    );
  }
}

class TimeAttackResultsScreen extends StatelessWidget {
  const TimeAttackResultsScreen({super.key, required this.result});

  final TimeAttackResult? result;

  @override
  Widget build(BuildContext context) {
    final result = this.result;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Exam Evaluation'),
      ),
      body: AppPage(
        children: [
          if (result == null)
            CleanCard(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Icon(Icons.info_outline_rounded, size: 42),
                    const SizedBox(height: 12),
                    const Text('No simulator result is available.'),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => context.go('/diagnostic'),
                      child: const Text('Back to Diagnostic'),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            _TimeAttackScoreHero(result: result),
            const SizedBox(height: 16),
            CleanCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('AI Feedback',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 10),
                    Text(
                      result.feedback,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: kTextSecondary,
                            height: 1.5,
                          ),
                    ),
                    if (result.metrics != null) ...[
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: InferenceBadge(
                          totalTimeSeconds: result.metrics!.totalTimeSeconds,
                          tokensPerSecond: result.metrics!.tokensPerSecond,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => context.go('/diagnostic'),
                    icon: const Icon(Icons.psychology_alt_rounded),
                    label: const Text('Train Again'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => context.go('/home'),
                    icon: const Icon(Icons.home_outlined),
                    label: const Text('Home'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _TimeAttackScoreHero extends StatelessWidget {
  const _TimeAttackScoreHero({required this.result});

  final TimeAttackResult result;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(
              result.autoSubmitted ? 'Auto-submitted at 00:00' : 'Submitted',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: result.autoSubmitted ? kDangerRed : kNeonGreen,
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 10),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: result.totalScore),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (context, value, child) {
                return Text(
                  value.toStringAsFixed(1),
                  style: Theme.of(context).textTheme.displayLarge?.copyWith(
                        color: kNeonGreen,
                        fontWeight: FontWeight.w900,
                      ),
                );
              },
            ),
            Text(
              'Final Combined Score / 100',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: kTextTertiary,
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 18),
            _ScoreBreakdownRow(
              label: 'Choice Sections',
              value:
                  '${result.objectiveScore.toStringAsFixed(1)}/70 (${result.objectiveCorrect}/${result.objectiveTotal})',
              icon: Icons.fact_check_outlined,
            ),
            _ScoreBreakdownRow(
              label: 'Translation',
              value: '${result.translationScore.toStringAsFixed(1)}/10',
              icon: Icons.translate_rounded,
            ),
            _ScoreBreakdownRow(
              label: 'Essay',
              value:
                  '${result.essayScore.toStringAsFixed(1)}/20 (${result.essayWordCount} words)',
              icon: Icons.edit_note_rounded,
            ),
            _ScoreBreakdownRow(
              label: 'Time Used',
              value: _formatDuration(result.timeUsed),
              icon: Icons.speed_rounded,
            ),
          ],
        ),
      ),
    );
  }
}

class _ScoreBreakdownRow extends StatelessWidget {
  const _ScoreBreakdownRow({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(icon, color: kElectricBlue, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: kTextSecondary,
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: kTextPrimary,
                  fontWeight: FontWeight.w900,
                ),
          ),
        ],
      ),
    );
  }
}

class SpeakerIconButton extends StatefulWidget {
  const SpeakerIconButton({
    super.key,
    required this.text,
    this.tooltip = 'Speak',
    this.compact = false,
  });

  final String text;
  final String tooltip;
  final bool compact;

  @override
  State<SpeakerIconButton> createState() => _SpeakerIconButtonState();
}

class _SpeakerIconButtonState extends State<SpeakerIconButton> {
  bool _isSpeaking = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _toggleSpeech,
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: _isSpeaking ? 'Stop audio' : widget.tooltip,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: widget.compact ? 38 : 44,
          height: widget.compact ? 38 : 44,
          decoration: BoxDecoration(
            color: _isSpeaking
                ? kNeonGreen.withOpacity(0.18)
                : kSurfaceGlassStrong,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: _isSpeaking ? kNeonGreen : kGlassBorder,
            ),
            boxShadow: _isSpeaking
                ? [
                    BoxShadow(
                      color: kNeonGreen.withOpacity(0.22),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            _isSpeaking ? Icons.stop_rounded : Icons.volume_up_rounded,
            color: _isSpeaking ? kNeonGreen : kTextSecondary,
            size: widget.compact ? 20 : 22,
          ),
        ),
      ),
    );
  }

  Future<void> _toggleSpeech() async {
    if (_isSpeaking) {
      await AudioService.instance.stop();
      if (mounted) {
        setState(() => _isSpeaking = false);
      }
      return;
    }

    setState(() => _isSpeaking = true);
    try {
      await AudioService.instance.speak(
        widget.text,
        onComplete: () {
          if (mounted) {
            setState(() => _isSpeaking = false);
          }
        },
        onError: _showTtsError,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSpeaking = false);
      _showTtsError('Text-to-speech is unavailable on this device.');
    }
  }

  void _showTtsError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message.isEmpty ? 'Unable to play audio.' : message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

class PassageAudioButton extends StatefulWidget {
  const PassageAudioButton({
    super.key,
    required this.text,
    this.label = 'Play Audio',
  });

  final String text;
  final String label;

  @override
  State<PassageAudioButton> createState() => _PassageAudioButtonState();
}

class _PassageAudioButtonState extends State<PassageAudioButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
      lowerBound: 0.94,
      upperBound: 1.06,
    )..value = 1.0;
  }

  @override
  void didUpdateWidget(covariant PassageAudioButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text && _isPlaying) {
      unawaited(AudioService.instance.stop());
      setState(() => _isPlaying = false);
      _pulseController.stop();
    }
  }

  @override
  void dispose() {
    if (_isPlaying) {
      unawaited(AudioService.instance.stop());
    }
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final button = FloatingActionButton.extended(
      heroTag: null,
      onPressed: _toggleAudio,
      backgroundColor: _isPlaying ? kNeonGreen : kElectricBlue,
      foregroundColor: _isPlaying ? const Color(0xFF052E1A) : Colors.white,
      icon: Icon(_isPlaying ? Icons.stop_rounded : Icons.volume_up_rounded),
      label: Text(_isPlaying ? 'Stop Audio' : widget.label),
    );

    return ScaleTransition(
      scale: _pulseController,
      child: button,
    );
  }

  Future<void> _toggleAudio() async {
    if (_isPlaying) {
      await AudioService.instance.stop();
      _stopPulse();
      return;
    }

    setState(() => _isPlaying = true);
    _pulseController.repeat(reverse: true);
    try {
      await AudioService.instance.speak(
        widget.text,
        onComplete: _stopPulse,
        onError: _showTtsError,
      );
    } catch (_) {
      _stopPulse();
      _showTtsError('Text-to-speech is unavailable on this device.');
    }
  }

  void _stopPulse() {
    if (!mounted) return;
    _pulseController.stop();
    _pulseController.value = 1.0;
    setState(() => _isPlaying = false);
  }

  void _showTtsError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message.isEmpty ? 'Unable to play audio.' : message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

class SkeletonShimmer extends StatefulWidget {
  const SkeletonShimmer({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  State<SkeletonShimmer> createState() => _SkeletonShimmerState();
}

class _SkeletonShimmerState extends State<SkeletonShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1350),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment(-1.2 + _controller.value * 2.4, -0.4),
              end: Alignment(-0.2 + _controller.value * 2.4, 0.4),
              colors: [
                Colors.white.withOpacity(0.06),
                Colors.white.withOpacity(0.20),
                Colors.white.withOpacity(0.06),
              ],
              stops: const [0.18, 0.5, 0.82],
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class SkeletonBlock extends StatelessWidget {
  const SkeletonBlock({
    super.key,
    required this.height,
    this.width,
    this.radius = 8,
  });

  final double height;
  final double? width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF263241).withOpacity(0.72),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withOpacity(0.035)),
      ),
    );
  }
}

class GrammarSkeleton extends StatelessWidget {
  const GrammarSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: CleanCard(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  SkeletonBlock(width: 42, height: 42),
                  SizedBox(width: 12),
                  Expanded(child: SkeletonBlock(height: 20)),
                ],
              ),
              const SizedBox(height: 22),
              const SkeletonBlock(height: 28),
              const SizedBox(height: 10),
              const SkeletonBlock(width: 260, height: 18),
              const SizedBox(height: 18),
              for (var index = 0; index < 4; index++) ...[
                const SkeletonBlock(height: 58),
                if (index != 3) const SizedBox(height: 10),
              ],
              const SizedBox(height: 16),
              const Align(
                alignment: Alignment.centerRight,
                child: SkeletonBlock(width: 118, height: 28, radius: 999),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ReadingSkeleton extends StatelessWidget {
  const ReadingSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: CleanCard(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SkeletonBlock(height: 26, width: 300),
              const SizedBox(height: 12),
              Row(
                children: const [
                  SkeletonBlock(width: 88, height: 32, radius: 999),
                  SizedBox(width: 8),
                  SkeletonBlock(width: 108, height: 32, radius: 999),
                  SizedBox(width: 8),
                  SkeletonBlock(width: 70, height: 32, radius: 999),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: const [
                  SkeletonBlock(width: 162, height: 44),
                  SizedBox(width: 10),
                  SkeletonBlock(width: 138, height: 44, radius: 999),
                ],
              ),
              const SizedBox(height: 20),
              for (final width in <double>[
                double.infinity,
                330,
                double.infinity,
                280,
                double.infinity,
                350,
                300,
              ]) ...[
                SkeletonBlock(
                    height: 14, width: width == double.infinity ? null : width),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class FlashcardSkeleton extends StatelessWidget {
  const FlashcardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: CleanCard(
        child: Container(
          height: 330,
          padding: const EdgeInsets.all(22),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: const [
                  SkeletonBlock(width: 38, height: 38, radius: 999),
                ],
              ),
              const Spacer(),
              const SkeletonBlock(width: 230, height: 38),
              const SizedBox(height: 18),
              const SkeletonBlock(width: 92, height: 5, radius: 999),
              const Spacer(),
              Row(
                children: const [
                  Expanded(child: SkeletonBlock(height: 54)),
                  SizedBox(width: 10),
                  Expanded(child: SkeletonBlock(height: 54)),
                  SizedBox(width: 10),
                  Expanded(child: SkeletonBlock(height: 54)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class UnifiedErrorState extends StatelessWidget {
  const UnifiedErrorState({
    super.key,
    required this.message,
    required this.onRetry,
    this.title = 'Something went sideways',
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          children: [
            Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                color: kElectricBlue.withOpacity(0.12),
                shape: BoxShape.circle,
                border: Border.all(color: kElectricBlue.withOpacity(0.42)),
                boxShadow: [
                  BoxShadow(
                    color: kElectricBlue.withOpacity(0.16),
                    blurRadius: 26,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: const Icon(
                Icons.cloud_off_rounded,
                color: kElectricBlue,
                size: 38,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: kTextSecondary,
                    height: 1.45,
                  ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final safeDuration = duration.isNegative ? Duration.zero : duration;
  final minutes =
      safeDuration.inMinutes.remainder(1000).toString().padLeft(2, '0');
  final seconds =
      safeDuration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

class DiscourseScreen extends StatefulWidget {
  const DiscourseScreen({super.key});

  @override
  State<DiscourseScreen> createState() => _DiscourseScreenState();
}

class _DiscourseScreenState extends State<DiscourseScreen> {
  static final Uri _discourseEndpoint = AppConfig.apiUri('/generate/discourse');

  DiscourseQuestion? _question;
  final Map<String, String> _assignments = <String, String>{};
  final Map<String, bool> _slotResults = <String, bool>{};
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadQuestion();
  }

  @override
  Widget build(BuildContext context) {
    final question = _question;
    final isTablet = isTabletLayout(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Discourse Training')),
      body: SafeArea(
        child: _buildBody(context, question, isTablet),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    DiscourseQuestion? question,
    bool isTablet,
  ) {
    if (_isLoading) {
      return const AppPage(
        children: [
          Hero(
            tag: 'discourse-training-flow',
            child: Material(
              color: Colors.transparent,
              child: _GlowingQuizLoader(),
            ),
          ),
        ],
      );
    }

    if (_errorMessage != null) {
      return AppPage(
        children: [
          Hero(
            tag: 'discourse-training-flow',
            child: Material(
              color: Colors.transparent,
              child: _QuizErrorState(
                message: _errorMessage!,
                onRetry: _loadQuestion,
              ),
            ),
          ),
        ],
      );
    }

    if (question == null) return const AppPage(children: []);

    final articleCard = Hero(
      tag: 'discourse-training-flow',
      child: Material(
        color: Colors.transparent,
        child: _DiscourseArticleCard(
          question: question,
          assignments: _assignments,
          slotResults: _slotResults,
          onAccept: _assignSentence,
        ),
      ),
    );
    final controls = _DiscourseControlsPanel(
      question: question,
      assignments: _assignments,
      slotResults: _slotResults,
      onClear: _clearAnswers,
      onSubmit: _assignments.length == 4 ? _submitAnswers : null,
    );

    if (isTablet) {
      return _ResponsiveBackdrop(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 8, 24),
                child: SingleChildScrollView(
                  child: _DiscoursePassageReferenceCard(question: question),
                ),
              ),
            ),
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 18, 24),
                child: SingleChildScrollView(
                  child: _DiscourseTabletInteractionPanel(
                    question: question,
                    assignments: _assignments,
                    slotResults: _slotResults,
                    onAccept: _assignSentence,
                    onClear: _clearAnswers,
                    onSubmit: _assignments.length == 4 ? _submitAnswers : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return AppPage(
      children: [
        articleCard,
        const SizedBox(height: 16),
        controls,
      ],
    );
  }

  Future<void> _loadQuestion() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _question = null;
      _assignments.clear();
      _slotResults.clear();
    });

    try {
      final response = await _authenticatedPost(
        _discourseEndpoint,
        body: jsonEncode(<String, String>{'mode': 'gsat_discourse'}),
      ).timeout(const Duration(seconds: 24));

      if (!mounted) return;
      final data = _decodeJsonObject(response.body);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() {
          _question = DiscourseQuestion.fromJson(data);
          _isLoading = false;
        });
      } else if (_isAiQuotaLimitResponse(response)) {
        setState(() {
          _errorMessage = 'Daily AI generation limit reached.';
          _isLoading = false;
        });
        unawaited(_showAiQuotaBottomSheet(context));
      } else {
        setState(() {
          _errorMessage = 'Status ${response.statusCode}';
          _isLoading = false;
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'The AI took too long to build this discourse drill.';
        _isLoading = false;
      });
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Cannot reach the discourse generator.';
        _isLoading = false;
      });
    } on AiQuotaExceededException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Daily AI generation limit reached.';
        _isLoading = false;
      });
      unawaited(_showAiQuotaBottomSheet(context));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to generate a discourse drill right now.';
        _isLoading = false;
      });
    }
  }

  void _assignSentence(String blankId, String sentence) {
    setState(() {
      _assignments.removeWhere((key, value) => value == sentence);
      _assignments[blankId] = sentence;
      _slotResults.clear();
    });
    unawaited(HapticFeedback.lightImpact());
  }

  void _clearAnswers() {
    setState(() {
      _assignments.clear();
      _slotResults.clear();
    });
  }

  Future<void> _submitAnswers() async {
    final question = _question;
    if (question == null) return;

    await HapticFeedback.heavyImpact();
    final results = <String, bool>{};
    for (final blankId in question.blankIds) {
      results[blankId] =
          _assignments[blankId] == question.correctMapping[blankId];
    }
    final isCorrect = results.values.every((result) => result);
    unawaited(_playGrammarAnswerHaptic(isCorrect));

    setState(() {
      _slotResults
        ..clear()
        ..addAll(results);
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            isCorrect
                ? 'Concept mastered: discourse structure restored.'
                : 'Some sentence links are off. Use the color hints and retry.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

class DiscourseQuestion {
  const DiscourseQuestion({
    required this.articleWithBlanks,
    required this.extractedSentences,
    required this.correctMapping,
    required this.metrics,
  });

  final String articleWithBlanks;
  final List<String> extractedSentences;
  final Map<String, String> correctMapping;
  final PerformanceMetrics? metrics;

  List<String> get blankIds =>
      const ['BLANK_1', 'BLANK_2', 'BLANK_3', 'BLANK_4'];

  factory DiscourseQuestion.fromJson(Map<String, dynamic> json) {
    final rawSentences = json['extracted_sentences'];
    final sentences = rawSentences is List
        ? rawSentences
            .map((sentence) => sentence.toString().trim())
            .where((sentence) => sentence.isNotEmpty)
            .take(4)
            .toList()
        : <String>[];
    while (sentences.length < 4) {
      sentences.add('Sentence ${sentences.length + 1}');
    }

    final rawMapping = json['correct_mapping'];
    final mapping = <String, String>{};
    if (rawMapping is Map) {
      for (final entry in rawMapping.entries) {
        final key =
            entry.key.toString().replaceAll('[', '').replaceAll(']', '');
        mapping[key] = entry.value.toString().trim();
      }
    }

    return DiscourseQuestion(
      articleWithBlanks: _stringFromJson(
        json,
        ['article_with_blanks', 'article'],
        fallback:
            'Paragraph one [BLANK_1]\n\nParagraph two [BLANK_2]\n\nParagraph three [BLANK_3]\n\nParagraph four [BLANK_4]',
      ),
      extractedSentences: sentences,
      correctMapping: {
        for (var index = 1; index <= 4; index++)
          'BLANK_$index': mapping['BLANK_$index'] ?? sentences[index - 1],
      },
      metrics: PerformanceMetrics.maybeFromResponse(json),
    );
  }
}

class _DiscourseArticleCard extends StatelessWidget {
  const _DiscourseArticleCard({
    required this.question,
    required this.assignments,
    required this.slotResults,
    required this.onAccept,
  });

  final DiscourseQuestion question;
  final Map<String, String> assignments;
  final Map<String, bool> slotResults;
  final void Function(String blankId, String sentence) onAccept;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFF101828),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.account_tree_outlined,
                    color: kNeonGreen,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'GSAT Discourse Structure',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (question.metrics != null)
                  InferenceBadge(
                    totalTimeSeconds: question.metrics!.totalTimeSeconds,
                    tokensPerSecond: question.metrics!.tokensPerSecond,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'Drag each extracted sentence into the blank where it best restores the article flow.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: kTextTertiary,
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 18),
            ..._buildArticlePieces(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildArticlePieces(BuildContext context) {
    final markerPattern = RegExp(r'\[BLANK_[1-4]\]');
    final widgets = <Widget>[];
    var currentIndex = 0;

    for (final match in markerPattern.allMatches(question.articleWithBlanks)) {
      final text =
          question.articleWithBlanks.substring(currentIndex, match.start);
      if (text.trim().isNotEmpty) {
        widgets.add(_DiscourseArticleText(text: text));
      }
      final blankId = match.group(0)!.replaceAll('[', '').replaceAll(']', '');
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: _DiscourseDropSlot(
            blankId: blankId,
            sentence: assignments[blankId],
            state: _slotState(blankId),
            onAccept: (sentence) => onAccept(blankId, sentence),
          ),
        ),
      );
      currentIndex = match.end;
    }

    final trailing = question.articleWithBlanks.substring(currentIndex);
    if (trailing.trim().isNotEmpty) {
      widgets.add(_DiscourseArticleText(text: trailing));
    }

    return widgets;
  }

  _DiscourseSlotState _slotState(String blankId) {
    if (!slotResults.containsKey(blankId)) return _DiscourseSlotState.idle;
    return slotResults[blankId]!
        ? _DiscourseSlotState.correct
        : _DiscourseSlotState.wrong;
  }
}

class _DiscoursePassageReferenceCard extends StatelessWidget {
  const _DiscoursePassageReferenceCard({required this.question});

  final DiscourseQuestion question;

  @override
  Widget build(BuildContext context) {
    final scale = tabletReadingTextScale(context);
    final baseStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: kTextSecondary,
          height: 1.62,
          fontSize:
              (Theme.of(context).textTheme.bodyLarge?.fontSize ?? 16) * scale,
        );

    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.article_outlined, color: kNeonGreen),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Passage Reference',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (question.metrics != null)
                  InferenceBadge(
                    totalTimeSeconds: question.metrics!.totalTimeSeconds,
                    tokensPerSecond: question.metrics!.tokensPerSecond,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            RichText(
              text: TextSpan(
                style: baseStyle,
                children: _buildReferenceSpans(question.articleWithBlanks),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<TextSpan> _buildReferenceSpans(String article) {
    final markerPattern = RegExp(r'\[BLANK_[1-4]\]');
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final match in markerPattern.allMatches(article)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: article.substring(cursor, match.start)));
      }
      spans.add(
        TextSpan(
          text: match.group(0),
          style: const TextStyle(
            color: kNeonGreen,
            fontWeight: FontWeight.w900,
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < article.length) {
      spans.add(TextSpan(text: article.substring(cursor)));
    }
    return spans;
  }
}

class _DiscourseArticleText extends StatelessWidget {
  const _DiscourseArticleText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scale = tabletReadingTextScale(context);
    return Text(
      text.trim(),
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: kTextSecondary,
            height: 1.58,
            fontSize:
                (Theme.of(context).textTheme.bodyLarge?.fontSize ?? 16) * scale,
          ),
    );
  }
}

enum _DiscourseSlotState { idle, correct, wrong }

class _DiscourseDropSlot extends StatelessWidget {
  const _DiscourseDropSlot({
    required this.blankId,
    required this.sentence,
    required this.state,
    required this.onAccept,
  });

  final String blankId;
  final String? sentence;
  final _DiscourseSlotState state;
  final ValueChanged<String> onAccept;

  @override
  Widget build(BuildContext context) {
    final colors = switch (state) {
      _DiscourseSlotState.correct => (
          background: kNeonGreen.withOpacity(0.12),
          border: kNeonGreen,
          foreground: kNeonGreen,
          icon: Icons.check_circle_rounded,
        ),
      _DiscourseSlotState.wrong => (
          background: kDangerRed.withOpacity(0.12),
          border: kDangerRed,
          foreground: kDangerRed,
          icon: Icons.cancel_rounded,
        ),
      _ => (
          background: kSurfaceGlassStrong,
          border: kGlassBorder,
          foreground: kTextSecondary,
          icon: Icons.open_with_rounded,
        ),
    };

    return DragTarget<String>(
      onWillAccept: (_) => true,
      onAccept: onAccept,
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 92),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isHovering
                ? kElectricBlue.withOpacity(0.16)
                : colors.background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isHovering ? kElectricBlue : colors.border,
              width: isHovering ? 1.8 : 1.2,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(colors.icon, color: colors.foreground, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  sentence ?? '$blankId  Drop sentence here',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: sentence == null
                            ? kTextTertiary
                            : colors.foreground,
                        fontWeight: sentence == null
                            ? FontWeight.w700
                            : FontWeight.w900,
                        height: 1.38,
                      ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DiscourseSentenceBank extends StatelessWidget {
  const _DiscourseSentenceBank({required this.sentences});

  final List<String> sentences;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Extracted sentences',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            if (sentences.isEmpty)
              Text(
                'All sentences are placed. Submit when ready.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: kTextTertiary,
                    ),
              )
            else
              for (final sentence in sentences) ...[
                _DraggableDiscourseSentence(sentence: sentence),
                if (sentence != sentences.last) const SizedBox(height: 10),
              ],
          ],
        ),
      ),
    );
  }
}

class _DiscourseControlsPanel extends StatelessWidget {
  const _DiscourseControlsPanel({
    required this.question,
    required this.assignments,
    required this.slotResults,
    required this.onClear,
    required this.onSubmit,
  });

  final DiscourseQuestion question;
  final Map<String, String> assignments;
  final Map<String, bool> slotResults;
  final VoidCallback onClear;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DiscourseSentenceBank(
          sentences: question.extractedSentences
              .where((sentence) => !assignments.containsValue(sentence))
              .toList(),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Clear'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: onSubmit,
                icon: const Icon(Icons.task_alt_rounded),
                label: const Text('Submit'),
              ),
            ),
          ],
        ),
        if (slotResults.isNotEmpty) ...[
          const SizedBox(height: 12),
          _StatusBanner(
            message: slotResults.values.every((result) => result)
                ? 'Perfect structure. The article flows naturally again.'
                : 'Almost there. Red slots need another look.',
            icon: slotResults.values.every((result) => result)
                ? Icons.check_circle_rounded
                : Icons.tips_and_updates_outlined,
            color: slotResults.values.every((result) => result)
                ? kNeonGreen
                : kElectricBlue,
            backgroundColor: slotResults.values.every((result) => result)
                ? kNeonGreen
                : kElectricBlue,
          ),
        ],
      ],
    );
  }
}

class _DiscourseTabletInteractionPanel extends StatelessWidget {
  const _DiscourseTabletInteractionPanel({
    required this.question,
    required this.assignments,
    required this.slotResults,
    required this.onAccept,
    required this.onClear,
    required this.onSubmit,
  });

  final DiscourseQuestion question;
  final Map<String, String> assignments;
  final Map<String, bool> slotResults;
  final void Function(String blankId, String sentence) onAccept;
  final VoidCallback onClear;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CleanCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Drop Targets',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 10),
                Text(
                  'Use the left passage as reference, then place each extracted sentence below.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: kTextTertiary,
                        height: 1.35,
                      ),
                ),
                const SizedBox(height: 14),
                for (final blankId in question.blankIds) ...[
                  _DiscourseDropSlot(
                    blankId: blankId,
                    sentence: assignments[blankId],
                    state: _slotState(blankId),
                    onAccept: (sentence) => onAccept(blankId, sentence),
                  ),
                  if (blankId != question.blankIds.last)
                    const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _DiscourseControlsPanel(
          question: question,
          assignments: assignments,
          slotResults: slotResults,
          onClear: onClear,
          onSubmit: onSubmit,
        ),
      ],
    );
  }

  _DiscourseSlotState _slotState(String blankId) {
    if (!slotResults.containsKey(blankId)) return _DiscourseSlotState.idle;
    return slotResults[blankId]!
        ? _DiscourseSlotState.correct
        : _DiscourseSlotState.wrong;
  }
}

class _DraggableDiscourseSentence extends StatelessWidget {
  const _DraggableDiscourseSentence({required this.sentence});

  final String sentence;

  @override
  Widget build(BuildContext context) {
    final card = _DiscourseSentenceCard(sentence: sentence);
    return Draggable<String>(
      data: sentence,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () => unawaited(HapticFeedback.selectionClick()),
      feedback: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(MediaQuery.of(context).size.width - 36, 430),
          ),
          child: _DiscourseSentenceCard(
            sentence: sentence,
            isFloating: true,
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: card),
      child: card,
    );
  }
}

class _DiscourseSentenceCard extends StatelessWidget {
  const _DiscourseSentenceCard({
    required this.sentence,
    this.isFloating = false,
  });

  final String sentence;
  final bool isFloating;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isFloating ? const Color(0xFF102033) : kSurfaceGlassStrong,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isFloating ? kElectricBlue : kGlassBorder,
          width: isFloating ? 1.7 : 1,
        ),
        boxShadow: isFloating
            ? [
                BoxShadow(
                  color: kElectricBlue.withOpacity(0.24),
                  blurRadius: 26,
                  offset: const Offset(0, 16),
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          const Icon(Icons.drag_indicator_rounded, color: kElectricBlue),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              sentence,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: kTextPrimary,
                    fontWeight: FontWeight.w800,
                    height: 1.35,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class ErrorLedgerScreen extends ConsumerStatefulWidget {
  const ErrorLedgerScreen({super.key});

  @override
  ConsumerState<ErrorLedgerScreen> createState() => _ErrorLedgerScreenState();
}

class _ErrorLedgerScreenState extends ConsumerState<ErrorLedgerScreen> {
  static final Uri _ledgerEndpoint = AppConfig.apiUri('/grammar/error-ledger');
  static final Uri _redemptionEndpoint =
      AppConfig.apiUri('/generate/grammar/redemption');

  List<GrammarLedgerEntry> _entries = const [];
  List<RedemptionQuizQuestion> _challengeQuestions = const [];
  PerformanceMetrics? _challengeMetrics;
  final Set<int> _masteredEntryIds = <int>{};
  bool _isLoading = true;
  bool _isGeneratingChallenge = false;
  bool _challengeComplete = false;
  bool _showMasteredPulse = false;
  int _challengeIndex = 0;
  int? _selectedOptionIndex;
  String? _errorMessage;
  String? _challengeError;

  @override
  void initState() {
    super.initState();
    _loadLedger();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Error Ledger')),
      body: AppPage(
        children: [
          const Hero(
            tag: 'error-ledger-flow',
            child: Material(
              color: Colors.transparent,
              child: _LedgerHeroCard(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed:
                _isGeneratingChallenge ? null : _startRedemptionChallenge,
            icon: _isGeneratingChallenge
                ? const Icon(Icons.hourglass_top_rounded)
                : const Icon(Icons.bolt_rounded),
            label: Text(
              _isGeneratingChallenge
                  ? 'Generating challenge...'
                  : 'Redemption Challenge (AI)',
            ),
          ),
          if (_challengeError != null) ...[
            const SizedBox(height: 12),
            _StatusBanner(
              message: _challengeError!,
              icon: Icons.info_outline_rounded,
              color: kElectricBlue,
              backgroundColor: kElectricBlue,
            ),
          ],
          if (_challengeQuestions.isNotEmpty || _challengeComplete) ...[
            const SizedBox(height: 16),
            _RedemptionQuizPanel(
              questions: _challengeQuestions,
              currentIndex: _challengeIndex,
              selectedIndex: _selectedOptionIndex,
              metrics: _challengeMetrics,
              isComplete: _challengeComplete,
              showMasteredPulse: _showMasteredPulse,
              onSelect: _selectRedemptionOption,
              onNext: _advanceChallenge,
              onRestart: _startRedemptionChallenge,
            ),
          ],
          const SizedBox(height: 18),
          Text(
            'Saved mistakes',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 12),
          if (_isLoading)
            const _LedgerLoadingState()
          else if (_errorMessage != null)
            _QuizErrorState(message: _errorMessage!, onRetry: _loadLedger)
          else if (_entries.isEmpty)
            const _EmptyLedgerState()
          else
            for (final entry in _entries) ...[
              _LedgerEntryTile(
                entry: entry,
                isMastered:
                    entry.isMastered || _masteredEntryIds.contains(entry.id),
              ),
              const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }

  Future<void> _loadLedger() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await _authenticatedGet(_ledgerEndpoint)
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        final items = decoded is List ? decoded : const [];
        final entries = items
            .whereType<Map>()
            .map((item) =>
                GrammarLedgerEntry.fromJson(Map<String, dynamic>.from(item)))
            .toList();

        setState(() {
          _entries = entries;
          _masteredEntryIds
            ..clear()
            ..addAll(entries
                .where((entry) => entry.isMastered)
                .map((entry) => entry.id));
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = 'Could not load the ledger (${response.statusCode}).';
          _isLoading = false;
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'The ledger request timed out.';
        _isLoading = false;
      });
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Backend is offline. Start FastAPI to view saved errors.';
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to load the error ledger right now.';
        _isLoading = false;
      });
    }
  }

  Future<void> _startRedemptionChallenge() async {
    setState(() {
      _isGeneratingChallenge = true;
      _challengeError = null;
      _challengeComplete = false;
      _selectedOptionIndex = null;
      _showMasteredPulse = false;
    });

    try {
      final response = await _authenticatedPost(
        _redemptionEndpoint,
        body: jsonEncode(<String, dynamic>{}),
      ).timeout(const Duration(seconds: 30));

      if (!mounted) return;
      final data = _decodeJsonObject(response.body);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final rawQuestions = data['questions'];
        final questions = rawQuestions is List
            ? rawQuestions
                .whereType<Map>()
                .map(
                  (item) => RedemptionQuizQuestion.fromJson(
                      Map<String, dynamic>.from(item)),
                )
                .toList()
            : <RedemptionQuizQuestion>[];

        setState(() {
          _challengeQuestions = questions;
          _challengeMetrics = PerformanceMetrics.maybeFromResponse(data);
          _challengeIndex = 0;
          _selectedOptionIndex = null;
          _challengeComplete = questions.isEmpty;
          _isGeneratingChallenge = false;
          _challengeError = questions.isEmpty
              ? 'AI returned no challenge questions. Try again in a moment.'
              : null;
        });
      } else if (_isAiQuotaLimitResponse(response)) {
        setState(() {
          _challengeError = 'Daily AI generation limit reached.';
          _isGeneratingChallenge = false;
        });
        unawaited(_showAiQuotaBottomSheet(context));
      } else {
        setState(() {
          _challengeError = _stringValue(
            data,
            ['detail', 'message', 'error'],
            fallback:
                'Redemption challenge failed with status ${response.statusCode}.',
          );
          _isGeneratingChallenge = false;
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _challengeError = 'The redemption generator timed out.';
        _isGeneratingChallenge = false;
      });
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _challengeError = 'Backend is offline. Start FastAPI and try again.';
        _isGeneratingChallenge = false;
      });
    } on AiQuotaExceededException {
      if (!mounted) return;
      setState(() {
        _challengeError = 'Daily AI generation limit reached.';
        _isGeneratingChallenge = false;
      });
      unawaited(_showAiQuotaBottomSheet(context));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _challengeError =
            'Unable to generate a redemption challenge right now.';
        _isGeneratingChallenge = false;
      });
    }
  }

  Future<void> _selectRedemptionOption(int index) async {
    if (_selectedOptionIndex != null || _challengeQuestions.isEmpty) return;

    final question = _challengeQuestions[_challengeIndex];
    final isCorrect = index == question.correctIndex;
    unawaited(_playGrammarAnswerHaptic(isCorrect));

    setState(() {
      _selectedOptionIndex = index;
      _showMasteredPulse = isCorrect;
      if (isCorrect) {
        _masteredEntryIds.addAll(question.ledgerErrorIds);
        _entries = [
          for (final entry in _entries)
            question.ledgerErrorIds.contains(entry.id)
                ? entry.copyWith(isMastered: true)
                : entry,
        ];
      }
    });

    if (isCorrect) {
      if (_challengeIndex >= _challengeQuestions.length - 1) {
        ref
            .read(rewardVFXControllerProvider)
            .trigger('redemption challenge passed');
      }
      for (final entryId in question.ledgerErrorIds) {
        unawaited(_markEntryMastered(entryId));
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Concept Mastered!'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      await Future<void>.delayed(const Duration(milliseconds: 1250));
      if (mounted && _selectedOptionIndex == index) {
        _advanceChallenge();
      }
    }
  }

  void _advanceChallenge() {
    if (_challengeQuestions.isEmpty) return;

    if (_challengeIndex >= _challengeQuestions.length - 1) {
      setState(() {
        _challengeComplete = true;
        _selectedOptionIndex = null;
        _showMasteredPulse = false;
      });
      return;
    }

    setState(() {
      _challengeIndex += 1;
      _selectedOptionIndex = null;
      _showMasteredPulse = false;
    });
  }

  Future<void> _markEntryMastered(int entryId) async {
    try {
      await _authenticatedPost(
        AppConfig.apiUri('/grammar/error-ledger/$entryId/mastered'),
        body: null,
        jsonContent: false,
      ).timeout(const Duration(seconds: 8));
    } catch (_) {
      // Local mastery feedback should stay instant even if persistence retries later.
    }
  }
}

class GrammarLedgerEntry {
  const GrammarLedgerEntry({
    required this.id,
    required this.errorType,
    required this.originalQuestion,
    required this.userAnswer,
    required this.correctAnswer,
    required this.explanation,
    required this.occurrenceCount,
    required this.isMastered,
    required this.createdAt,
  });

  final int id;
  final String errorType;
  final String originalQuestion;
  final String? userAnswer;
  final String? correctAnswer;
  final String? explanation;
  final int occurrenceCount;
  final bool isMastered;
  final DateTime? createdAt;

  factory GrammarLedgerEntry.fromJson(Map<String, dynamic> json) {
    return GrammarLedgerEntry(
      id: PerformanceMetrics._asInt(json['id']),
      errorType: _stringFromJson(
        json,
        ['error_type', 'concept'],
        fallback: 'grammar_quiz',
      ),
      originalQuestion: _stringFromJson(
        json,
        ['original_question', 'original_sentence', 'question'],
        fallback: 'Saved grammar question',
      ),
      userAnswer: _nullableString(json['user_answer']),
      correctAnswer:
          _nullableString(json['correct_answer'] ?? json['corrected_sentence']),
      explanation: _nullableString(json['explanation']),
      occurrenceCount: PerformanceMetrics._asInt(json['occurrence_count']),
      isMastered: _boolFromJson(json['is_mastered']),
      createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()),
    );
  }

  GrammarLedgerEntry copyWith({bool? isMastered}) {
    return GrammarLedgerEntry(
      id: id,
      errorType: errorType,
      originalQuestion: originalQuestion,
      userAnswer: userAnswer,
      correctAnswer: correctAnswer,
      explanation: explanation,
      occurrenceCount: occurrenceCount,
      isMastered: isMastered ?? this.isMastered,
      createdAt: createdAt,
    );
  }
}

class RedemptionQuizQuestion {
  const RedemptionQuizQuestion({
    required this.concept,
    required this.question,
    required this.options,
    required this.correctIndex,
    required this.explanation,
    required this.ledgerErrorIds,
  });

  final String concept;
  final String question;
  final List<String> options;
  final int correctIndex;
  final String explanation;
  final List<int> ledgerErrorIds;

  factory RedemptionQuizQuestion.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    final options = rawOptions is List
        ? rawOptions.map((option) => option.toString()).toList()
        : const [
            'She has studied English for three years.',
            'She studied English since three years.',
            'She studies English from three years.',
            'She is study English for three years.',
          ];
    final safeOptions =
        options.length >= 4 ? options.take(4).toList() : options;
    while (safeOptions.length < 4) {
      safeOptions.add('Option ${safeOptions.length + 1}');
    }

    final rawIds = json['ledger_error_ids'];
    final ledgerIds = rawIds is List
        ? rawIds
            .map(PerformanceMetrics._asInt)
            .where((entryId) => entryId > 0)
            .toList()
        : <int>[];
    final correctIndex = PerformanceMetrics._asInt(
      json['correct_option_index'] ?? json['correct_index'],
    );

    return RedemptionQuizQuestion(
      concept:
          _stringFromJson(json, ['concept', 'error_type'], fallback: 'Grammar'),
      question: _stringFromJson(
        json,
        ['question', 'prompt'],
        fallback: 'Choose the grammatically correct sentence.',
      ),
      options: safeOptions,
      correctIndex: correctIndex >= 0 && correctIndex < safeOptions.length
          ? correctIndex
          : 0,
      explanation: _stringFromJson(
        json,
        ['explanation', 'correction'],
        fallback:
            'Review the grammar pattern and compare each option carefully.',
      ),
      ledgerErrorIds: ledgerIds,
    );
  }
}

class _LedgerHeroCard extends StatelessWidget {
  const _LedgerHeroCard();

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: kNeonGreen.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kNeonGreen.withOpacity(0.35)),
              ),
              child: const Icon(Icons.fact_check_rounded, color: kNeonGreen),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Grammar Error Ledger',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Turn saved mistakes into targeted comeback drills.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: kTextTertiary,
                          height: 1.35,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LedgerLoadingState extends StatelessWidget {
  const _LedgerLoadingState();

  @override
  Widget build(BuildContext context) {
    return const GrammarSkeleton();
  }
}

class _EmptyLedgerState extends StatelessWidget {
  const _EmptyLedgerState();

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          children: [
            Icon(
              Icons.bookmark_added_outlined,
              size: 46,
              color: kElectricBlue.withOpacity(0.85),
            ),
            const SizedBox(height: 12),
            Text(
              'No saved mistakes yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              'Save tough grammar quiz items and they will appear here.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: kTextTertiary,
                    height: 1.4,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LedgerEntryTile extends StatelessWidget {
  const _LedgerEntryTile({
    required this.entry,
    required this.isMastered,
  });

  final GrammarLedgerEntry entry;
  final bool isMastered;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w900,
          decoration: isMastered ? TextDecoration.lineThrough : null,
          color: isMastered ? kTextTertiary : kTextPrimary,
        );

    return AnimatedOpacity(
      opacity: isMastered ? 0.62 : 1,
      duration: const Duration(milliseconds: 260),
      child: CleanCard(
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            iconColor: kNeonGreen,
            collapsedIconColor: kTextTertiary,
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    _conceptLabel(entry.errorType),
                    style: titleStyle,
                  ),
                ),
                if (isMastered)
                  const Icon(Icons.verified_rounded,
                      color: kNeonGreen, size: 20),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                entry.originalQuestion,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: kTextTertiary,
                      decoration:
                          isMastered ? TextDecoration.lineThrough : null,
                    ),
              ),
            ),
            children: [
              _LedgerAnswerLine(
                label: 'Question',
                value: entry.originalQuestion,
                icon: Icons.help_outline_rounded,
              ),
              _LedgerAnswerLine(
                label: 'Your answer',
                value: entry.userAnswer ?? 'Not recorded',
                icon: Icons.person_outline_rounded,
                color: kDangerRed,
              ),
              _LedgerAnswerLine(
                label: 'Correct answer',
                value: entry.correctAnswer ?? 'Not recorded',
                icon: Icons.check_circle_outline_rounded,
                color: kNeonGreen,
              ),
              _LedgerAnswerLine(
                label: 'Explanation',
                value: entry.explanation ?? 'No explanation was saved.',
                icon: Icons.school_outlined,
                color: kElectricBlue,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LedgerAnswerLine extends StatelessWidget {
  const _LedgerAnswerLine({
    required this.label,
    required this.value,
    required this.icon,
    this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? kTextSecondary;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: kTextSecondary,
                        height: 1.38,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RedemptionQuizPanel extends StatelessWidget {
  const _RedemptionQuizPanel({
    required this.questions,
    required this.currentIndex,
    required this.selectedIndex,
    required this.metrics,
    required this.isComplete,
    required this.showMasteredPulse,
    required this.onSelect,
    required this.onNext,
    required this.onRestart,
  });

  final List<RedemptionQuizQuestion> questions;
  final int currentIndex;
  final int? selectedIndex;
  final PerformanceMetrics? metrics;
  final bool isComplete;
  final bool showMasteredPulse;
  final ValueChanged<int> onSelect;
  final VoidCallback onNext;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    if (isComplete) {
      return CleanCard(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              const Icon(Icons.workspace_premium_rounded,
                  color: kNeonGreen, size: 52),
              const SizedBox(height: 12),
              Text(
                'Redemption run complete',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Mastered concepts are now crossed out in your ledger.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: kTextTertiary,
                      height: 1.4,
                    ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRestart,
                icon: const Icon(Icons.replay_rounded),
                label: const Text('Run another challenge'),
              ),
            ],
          ),
        ),
      );
    }

    if (questions.isEmpty) return const SizedBox.shrink();

    final question = questions[currentIndex];
    final hasAnswered = selectedIndex != null;
    final isCorrect = selectedIndex == question.correctIndex;

    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Challenge ${currentIndex + 1}/${questions.length}',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: kNeonGreen,
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                ),
                if (metrics != null)
                  InferenceBadge(
                    totalTimeSeconds: metrics!.totalTimeSeconds,
                    tokensPerSecond: metrics!.tokensPerSecond,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _conceptLabel(question.concept),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: kElectricBlue,
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 12),
            Text(
              question.question,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    height: 1.26,
                  ),
            ),
            const SizedBox(height: 16),
            for (var index = 0; index < question.options.length; index++) ...[
              _QuizOptionTile(
                label: String.fromCharCode(65 + index),
                text: question.options[index],
                state: _redemptionOptionState(index, question, selectedIndex),
                onTap: () => onSelect(index),
              ),
              if (index != question.options.length - 1)
                const SizedBox(height: 10),
            ],
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              child: showMasteredPulse
                  ? const Padding(
                      key: ValueKey('pulse'),
                      padding: EdgeInsets.only(top: 16),
                      child: _ConceptMasteredPulse(),
                    )
                  : const SizedBox.shrink(key: ValueKey('no-pulse')),
            ),
            if (hasAnswered) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: (isCorrect ? kNeonGreen : kDangerRed).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color:
                        (isCorrect ? kNeonGreen : kDangerRed).withOpacity(0.35),
                  ),
                ),
                child: Text(
                  question.explanation,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: kTextSecondary,
                        height: 1.42,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              if (!isCorrect) ...[
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: onNext,
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: const Text('Next question'),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ConceptMasteredPulse extends StatefulWidget {
  const _ConceptMasteredPulse();

  @override
  State<_ConceptMasteredPulse> createState() => _ConceptMasteredPulseState();
}

class _ConceptMasteredPulseState extends State<_ConceptMasteredPulse> {
  final GlobalKey _shareKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.84, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.elasticOut,
      builder: (context, scale, child) {
        return Transform.scale(
          scale: scale,
          child: child,
        );
      },
      child: Column(
        children: [
          RepaintBoundary(
            key: _shareKey,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              decoration: BoxDecoration(
                color: kNeonGreen.withOpacity(0.14),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kNeonGreen.withOpacity(0.5)),
                boxShadow: [
                  BoxShadow(
                    color: kNeonGreen.withOpacity(0.18),
                    blurRadius: 22,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: const Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.verified_rounded, color: kNeonGreen),
                      SizedBox(width: 8),
                      Text(
                        'Concept Mastered!',
                        style: TextStyle(
                          color: kNeonGreen,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 10),
                  ShareWatermark(),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: () => ShareCaptureService.shareBoundary(
                context: context,
                boundaryKey: _shareKey,
                fileName: 'gsat-english-concept-mastered.png',
                shareText: 'I mastered a GSAT English concept with GSAT_Max.',
              ),
              icon: const Icon(Icons.ios_share_rounded, color: kElectricBlue),
              label: const Text('Share Progress'),
            ),
          ),
        ],
      ),
    );
  }
}

_QuizOptionState _redemptionOptionState(
  int index,
  RedemptionQuizQuestion question,
  int? selectedIndex,
) {
  if (selectedIndex == null) return _QuizOptionState.idle;
  if (index == question.correctIndex) return _QuizOptionState.correct;
  if (index == selectedIndex) return _QuizOptionState.wrong;
  return _QuizOptionState.dimmed;
}

String? _nullableString(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

bool _boolFromJson(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.toLowerCase().trim();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }
  return false;
}

String _conceptLabel(String value) {
  final words = value
      .replaceAll('_', ' ')
      .split(' ')
      .where((word) => word.trim().isNotEmpty)
      .toList();
  if (words.isEmpty) return 'Grammar';
  return words
      .map((word) => word[0].toUpperCase() + word.substring(1).toLowerCase())
      .join(' ');
}

class SentenceLevelUpScreen extends StatefulWidget {
  const SentenceLevelUpScreen({super.key});

  @override
  State<SentenceLevelUpScreen> createState() => _SentenceLevelUpScreenState();
}

class _SentenceLevelUpScreenState extends State<SentenceLevelUpScreen> {
  static final Uri _generateEndpoint =
      AppConfig.apiUri('/generate/sentence-upgrade');
  static final Uri _evaluateEndpoint =
      AppConfig.apiUri('/evaluate/sentence-upgrade');

  final TextEditingController _answerController = TextEditingController();
  SentenceUpgradePrompt? _prompt;
  SentenceUpgradeFeedback? _feedback;
  bool _isLoading = true;
  bool _isEvaluating = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadPrompt();
  }

  @override
  void dispose() {
    _answerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prompt = _prompt;
    return Scaffold(
      appBar: AppBar(title: const Text('Sentence Level-Up')),
      body: SafeArea(
        child: AppPage(
          children: [
            const PageIntro(
              icon: Icons.upgrade_rounded,
              title: '句子升級',
              subtitle:
                  'Swipe for a new prompt, then rewrite with the required advanced structure.',
            ),
            const SizedBox(height: 16),
            if (_isLoading)
              const GrammarSkeleton()
            else if (_errorMessage != null)
              UnifiedErrorState(
                message: _errorMessage!,
                title: 'Level-up prompt needs a refresh',
                onRetry: _loadPrompt,
              )
            else if (prompt != null) ...[
              Dismissible(
                key: ValueKey(
                    '${prompt.basicSentence}-${prompt.targetStructure}'),
                direction: DismissDirection.horizontal,
                onDismissed: (_) => _loadPrompt(forceRefresh: true),
                child: _SentenceUpgradePromptCard(prompt: prompt),
              ),
              const SizedBox(height: 16),
              CleanCard(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Your upgraded sentence',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _answerController,
                        minLines: 3,
                        maxLines: 6,
                        decoration: const InputDecoration(
                          hintText: 'Rewrite the sentence here...',
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _isEvaluating ? null : _evaluateAnswer,
                              icon: Icon(
                                _isEvaluating
                                    ? Icons.hourglass_top_rounded
                                    : Icons.bolt_rounded,
                              ),
                              label: Text(_isEvaluating
                                  ? 'Checking...'
                                  : 'Instant Check'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          IconButton.filledTonal(
                            tooltip: 'New prompt',
                            onPressed: _isEvaluating
                                ? null
                                : () => _loadPrompt(forceRefresh: true),
                            icon: const Icon(Icons.swipe_rounded),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (_feedback != null) ...[
                const SizedBox(height: 16),
                _SentenceUpgradeFeedbackCard(feedback: _feedback!),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _loadPrompt({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _feedback = null;
      _answerController.clear();
    });
    try {
      final response = await _authenticatedPost(
        _generateEndpoint,
        body: jsonEncode({
          'focus': forceRefresh ? 'rotating advanced GSAT structure' : null,
          'force_refresh': forceRefresh,
        }),
      ).timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() {
          _prompt =
              SentenceUpgradePrompt.fromJson(_decodeJsonObject(response.body));
          _isLoading = false;
        });
      } else {
        _throwIfAiQuotaExceeded(response);
        setState(() {
          _errorMessage = 'Generator returned ${response.statusCode}.';
          _isLoading = false;
        });
      }
    } on AiQuotaExceededException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Daily AI generation limit reached.';
        _isLoading = false;
      });
      unawaited(_showAiQuotaBottomSheet(context));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to generate a sentence upgrade prompt.';
        _isLoading = false;
      });
    }
  }

  Future<void> _evaluateAnswer() async {
    final prompt = _prompt;
    final answer = _answerController.text.trim();
    if (prompt == null || answer.isEmpty || _isEvaluating) return;

    setState(() {
      _isEvaluating = true;
      _feedback = null;
    });
    try {
      final response = await _authenticatedPost(
        _evaluateEndpoint,
        body: jsonEncode({
          'basic_sentence': prompt.basicSentence,
          'target_structure': prompt.targetStructure,
          'student_sentence': answer,
        }),
      ).timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final feedback = SentenceUpgradeFeedback.fromJson(
          _decodeJsonObject(response.body),
        );
        setState(() {
          _feedback = feedback;
        });
        unawaited(feedback.passed
            ? HapticFeedback.mediumImpact()
            : HapticFeedback.vibrate());
      } else {
        _throwIfAiQuotaExceeded(response);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Evaluation failed with ${response.statusCode}.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } on AiQuotaExceededException {
      if (!mounted) return;
      unawaited(_showAiQuotaBottomSheet(context));
    } finally {
      if (mounted) {
        setState(() {
          _isEvaluating = false;
        });
      }
    }
  }
}

class _SentenceUpgradePromptCard extends StatelessWidget {
  const _SentenceUpgradePromptCard({required this.prompt});

  final SentenceUpgradePrompt prompt;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: kElectricBlue.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kElectricBlue.withOpacity(0.42)),
                  ),
                  child: const Icon(Icons.swipe_rounded, color: kElectricBlue),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    prompt.targetStructure,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (prompt.metrics != null)
                  InferenceBadge(
                    totalTimeSeconds: prompt.metrics!.totalTimeSeconds,
                    tokensPerSecond: prompt.metrics!.tokensPerSecond,
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              prompt.basicSentence,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: kTextPrimary,
                    fontWeight: FontWeight.w900,
                    height: 1.22,
                  ),
            ),
            const SizedBox(height: 14),
            _InlineStatusPill(
              icon: Icons.tips_and_updates_outlined,
              message: prompt.instruction,
              color: kNeonGreen,
            ),
            const SizedBox(height: 10),
            Text(
              'Swipe this card sideways for a new prompt.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: kTextTertiary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SentenceUpgradeFeedbackCard extends StatelessWidget {
  const _SentenceUpgradeFeedbackCard({required this.feedback});

  final SentenceUpgradeFeedback feedback;

  @override
  Widget build(BuildContext context) {
    final color = feedback.passed ? kNeonGreen : kDangerRed;
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  feedback.passed
                      ? Icons.check_circle_rounded
                      : Icons.cancel_rounded,
                  color: color,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    feedback.passed ? 'Pass' : 'Try Again',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                ),
                if (feedback.metrics != null)
                  InferenceBadge(
                    totalTimeSeconds: feedback.metrics!.totalTimeSeconds,
                    tokensPerSecond: feedback.metrics!.tokensPerSecond,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              feedback.feedback,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: kTextSecondary,
                    height: 1.45,
                  ),
            ),
            const SizedBox(height: 14),
            Text('Suggested upgrade',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              feedback.suggestedUpgrade,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: kTextPrimary,
                    fontWeight: FontWeight.w800,
                    height: 1.45,
                  ),
            ),
            const SizedBox(height: 10),
            _InlineStatusPill(
              icon: Icons.architecture_rounded,
              message: 'Detected: ${feedback.detectedStructure}',
              color: kElectricBlue,
            ),
          ],
        ),
      ),
    );
  }
}

class ClozePracticeScreen extends StatefulWidget {
  const ClozePracticeScreen({super.key});

  @override
  State<ClozePracticeScreen> createState() => _ClozePracticeScreenState();
}

class _ClozePracticeScreenState extends State<ClozePracticeScreen> {
  static final Uri _endpoint = AppConfig.apiUri('/generate/cloze-phrases');

  ClozePhraseSet? _set;
  final Map<String, String> _assignments = <String, String>{};
  final Map<String, bool> _results = <String, bool>{};
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadSet();
  }

  @override
  Widget build(BuildContext context) {
    final set = _set;
    return Scaffold(
      appBar: AppBar(title: const Text('Dynamic Cloze Test')),
      body: SafeArea(
        child: AppPage(
          children: [
            const PageIntro(
              icon: Icons.extension_rounded,
              title: '文意選填 Cloze',
              subtitle:
                  'Drag GSAT phrasal verbs and collocations into the story blanks.',
            ),
            const SizedBox(height: 16),
            if (_isLoading)
              const ReadingSkeleton()
            else if (_errorMessage != null)
              UnifiedErrorState(
                message: _errorMessage!,
                title: 'Cloze generator needs a refresh',
                onRetry: _loadSet,
              )
            else if (set != null) ...[
              CleanCard(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('Story',
                              style: Theme.of(context).textTheme.titleLarge),
                          const Spacer(),
                          if (set.metrics != null)
                            InferenceBadge(
                              totalTimeSeconds: set.metrics!.totalTimeSeconds,
                              tokensPerSecond: set.metrics!.tokensPerSecond,
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _ClozeStoryText(
                        text: set.text,
                        assignments: _assignments,
                        results: _results,
                        onAccept: _assignPhrase,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _ClozePhraseBank(
                phrases: set.phrases
                    .where((phrase) => !_assignments.containsValue(phrase))
                    .toList(),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _clearAnswers,
                      icon: const Icon(Icons.restart_alt_rounded),
                      label: const Text('Clear'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed:
                          _assignments.length == 10 ? _submitAnswers : null,
                      icon: const Icon(Icons.task_alt_rounded),
                      label: const Text('Submit'),
                    ),
                  ),
                ],
              ),
              if (_results.isNotEmpty) ...[
                const SizedBox(height: 12),
                _StatusBanner(
                  message: _results.values.every((result) => result)
                      ? 'Perfect. Every collocation fits naturally.'
                      : 'Some blanks are off. Red slots need another phrase.',
                  icon: _results.values.every((result) => result)
                      ? Icons.check_circle_rounded
                      : Icons.tips_and_updates_outlined,
                  color: _results.values.every((result) => result)
                      ? kNeonGreen
                      : kDangerRed,
                  backgroundColor: _results.values.every((result) => result)
                      ? kNeonGreen
                      : kDangerRed,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _loadSet() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _assignments.clear();
      _results.clear();
    });
    try {
      final response = await _authenticatedPost(
        _endpoint,
        body: jsonEncode({'topic': 'school life and exam preparation'}),
      ).timeout(const Duration(seconds: 35));
      if (!mounted) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() {
          _set = ClozePhraseSet.fromJson(_decodeJsonObject(response.body));
          _isLoading = false;
        });
      } else {
        _throwIfAiQuotaExceeded(response);
        setState(() {
          _errorMessage = 'Generator returned ${response.statusCode}.';
          _isLoading = false;
        });
      }
    } on AiQuotaExceededException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Daily AI generation limit reached.';
        _isLoading = false;
      });
      unawaited(_showAiQuotaBottomSheet(context));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to generate a cloze drill right now.';
        _isLoading = false;
      });
    }
  }

  void _assignPhrase(String blankId, String phrase) {
    setState(() {
      _assignments.removeWhere((key, value) => value == phrase);
      _assignments[blankId] = phrase;
      _results.clear();
    });
    unawaited(HapticFeedback.lightImpact());
  }

  void _clearAnswers() {
    setState(() {
      _assignments.clear();
      _results.clear();
    });
    unawaited(HapticFeedback.selectionClick());
  }

  void _submitAnswers() {
    final set = _set;
    if (set == null) return;
    final results = <String, bool>{};
    for (var index = 1; index <= 10; index++) {
      final blankId = 'BLANK_$index';
      results[blankId] = _assignments[blankId] == set.correctMapping[blankId];
    }
    setState(() {
      _results
        ..clear()
        ..addAll(results);
    });
    final perfect = results.values.every((result) => result);
    unawaited(
        perfect ? HapticFeedback.mediumImpact() : HapticFeedback.vibrate());
  }
}

class _ClozeStoryText extends StatelessWidget {
  const _ClozeStoryText({
    required this.text,
    required this.assignments,
    required this.results,
    required this.onAccept,
  });

  final String text;
  final Map<String, String> assignments;
  final Map<String, bool> results;
  final void Function(String blankId, String phrase) onAccept;

  @override
  Widget build(BuildContext context) {
    final spans = <Widget>[];
    final pattern = RegExp(r'\[BLANK_(\d+)\]');
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(Text(
          text.substring(cursor, match.start),
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: kTextSecondary,
                height: 1.55,
              ),
        ));
      }
      final blankId = 'BLANK_${match.group(1)}';
      spans.add(_ClozeBlankSlot(
        blankId: blankId,
        phrase: assignments[blankId],
        result: results[blankId],
        onAccept: onAccept,
      ));
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(Text(
        text.substring(cursor),
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: kTextSecondary,
              height: 1.55,
            ),
      ));
    }
    return Wrap(
      spacing: 6,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: spans,
    );
  }
}

class _ClozeBlankSlot extends StatelessWidget {
  const _ClozeBlankSlot({
    required this.blankId,
    required this.phrase,
    required this.result,
    required this.onAccept,
  });

  final String blankId;
  final String? phrase;
  final bool? result;
  final void Function(String blankId, String phrase) onAccept;

  @override
  Widget build(BuildContext context) {
    final color = result == null
        ? kElectricBlue
        : result!
            ? kNeonGreen
            : kDangerRed;
    return DragTarget<String>(
      onWillAccept: (_) => result == null,
      onAccept: (value) => onAccept(blankId, value),
      builder: (context, candidateData, rejectedData) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          constraints: const BoxConstraints(minWidth: 138, minHeight: 38),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color.withOpacity(candidateData.isNotEmpty ? 0.18 : 0.10),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withOpacity(0.62)),
          ),
          child: Text(
            phrase ?? blankId.replaceAll('_', ' '),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: phrase == null ? kTextTertiary : color,
              fontWeight: FontWeight.w900,
            ),
          ),
        );
      },
    );
  }
}

class _ClozePhraseBank extends StatelessWidget {
  const _ClozePhraseBank({required this.phrases});

  final List<String> phrases;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Phrase Bank', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final phrase in phrases)
                  _DraggableClozePhrase(phrase: phrase),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DraggableClozePhrase extends StatelessWidget {
  const _DraggableClozePhrase({required this.phrase});

  final String phrase;

  @override
  Widget build(BuildContext context) {
    final chip = Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: kSurfaceGlassStrong,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: kNeonGreen.withOpacity(0.42)),
        ),
        child: Text(
          phrase,
          style: const TextStyle(
            color: kTextPrimary,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
    return Draggable<String>(
      data: phrase,
      feedback: chip,
      childWhenDragging: Opacity(opacity: 0.32, child: chip),
      child: chip,
    );
  }
}

class TranslationScreen extends StatefulWidget {
  const TranslationScreen({super.key});

  @override
  State<TranslationScreen> createState() => _TranslationScreenState();
}

class _TranslationScreenState extends State<TranslationScreen> {
  static final Uri _evaluateEndpoint =
      AppConfig.apiUri('/evaluate/translation');
  static final Uri _similarEndpoint =
      AppConfig.apiUri('/generate/translation-similar');

  final TextEditingController _chineseController = TextEditingController(
    text: '如果我們能善用時間，就能在考試前建立更多信心。',
  );
  final TextEditingController _translationController = TextEditingController();
  TranslationEvaluationResult? _result;
  String _activeConcept = 'conditional_sentence';
  bool _isEvaluating = false;
  bool _isGeneratingSimilar = false;
  String? _errorMessage;

  @override
  void dispose() {
    _chineseController.dispose();
    _translationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Translation Practice')),
      body: SafeArea(
        child: AppPage(
          children: [
            const PageIntro(
              icon: Icons.translate_rounded,
              title: '中翻英 Translation',
              subtitle:
                  'Strict GSAT grading: 4 points per sentence, with precise deductions.',
            ),
            const SizedBox(height: 16),
            CleanCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Chinese Sentence',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _chineseController,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: '輸入要翻譯的中文句子...',
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('Your English Translation',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _translationController,
                      minLines: 3,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        hintText: 'Type your English translation...',
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed:
                                _isEvaluating ? null : _submitTranslation,
                            icon: Icon(
                              _isEvaluating
                                  ? Icons.hourglass_top_rounded
                                  : Icons.fact_check_rounded,
                            ),
                            label: Text(_isEvaluating
                                ? 'Grading...'
                                : 'Grade Strictly'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton.filledTonal(
                          tooltip: 'Try Similar Sentence',
                          onPressed:
                              _isGeneratingSimilar ? null : _trySimilarSentence,
                          icon: Icon(
                            _isGeneratingSimilar
                                ? Icons.hourglass_empty_rounded
                                : Icons.auto_awesome_rounded,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              UnifiedErrorState(
                message: _errorMessage!,
                title: 'Translation grader needs a refresh',
                onRetry: _submitTranslation,
              ),
            ],
            if (_result != null) ...[
              const SizedBox(height: 16),
              _TranslationResultCard(
                result: _result!,
                studentTranslation: _translationController.text,
                onTrySimilar: _trySimilarSentence,
                isGeneratingSimilar: _isGeneratingSimilar,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _submitTranslation() async {
    final chinese = _chineseController.text.trim();
    final translation = _translationController.text.trim();
    if (chinese.isEmpty || translation.isEmpty) {
      setState(() {
        _errorMessage =
            'Please enter both the Chinese sentence and your English translation.';
      });
      return;
    }

    setState(() {
      _isEvaluating = true;
      _errorMessage = null;
    });

    try {
      final response = await _authenticatedPost(
        _evaluateEndpoint,
        body: jsonEncode({
          'chinese_sentence': chinese,
          'student_translation': translation,
          'grammar_concept': _activeConcept,
        }),
      ).timeout(const Duration(seconds: 35));
      if (!mounted) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final result = TranslationEvaluationResult.fromJson(
          _decodeJsonObject(response.body),
        );
        setState(() {
          _result = result;
          _activeConcept = result.grammarConcept;
        });
        unawaited(HapticFeedback.mediumImpact());
      } else {
        _throwIfAiQuotaExceeded(response);
        setState(() {
          _errorMessage = 'Grading failed with status ${response.statusCode}.';
        });
      }
    } on AiQuotaExceededException {
      if (!mounted) return;
      unawaited(_showAiQuotaBottomSheet(context));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to grade this translation right now.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isEvaluating = false;
        });
      }
    }
  }

  Future<void> _trySimilarSentence() async {
    if (_isGeneratingSimilar) return;
    setState(() {
      _isGeneratingSimilar = true;
      _errorMessage = null;
    });

    try {
      final response = await _authenticatedPost(
        _similarEndpoint,
        body: jsonEncode({
          'grammar_concept': _activeConcept,
          'source_sentence': _chineseController.text.trim(),
        }),
      ).timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = _decodeJsonObject(response.body);
        setState(() {
          _chineseController.text = _stringFromAny(
            data['chinese_sentence'],
            fallback: _chineseController.text,
          );
          _activeConcept = _stringFromAny(
            data['grammar_concept'],
            fallback: _activeConcept,
          );
          _translationController.clear();
          _result = null;
        });
        unawaited(HapticFeedback.selectionClick());
      } else {
        _throwIfAiQuotaExceeded(response);
        setState(() {
          _errorMessage = 'Could not generate a similar sentence.';
        });
      }
    } on AiQuotaExceededException {
      if (!mounted) return;
      unawaited(_showAiQuotaBottomSheet(context));
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingSimilar = false;
        });
      }
    }
  }
}

class _TranslationResultCard extends StatelessWidget {
  const _TranslationResultCard({
    required this.result,
    required this.studentTranslation,
    required this.onTrySimilar,
    required this.isGeneratingSimilar,
  });

  final TranslationEvaluationResult result;
  final String studentTranslation;
  final VoidCallback onTrySimilar;
  final bool isGeneratingSimilar;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${result.finalScore.toStringAsFixed(1)} / 4.0',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color:
                            result.finalScore >= 3.5 ? kNeonGreen : kDangerRed,
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const Spacer(),
                if (result.metrics != null)
                  InferenceBadge(
                    totalTimeSeconds: result.metrics!.totalTimeSeconds,
                    tokensPerSecond: result.metrics!.tokensPerSecond,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Marked Translation',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.035),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kGlassBorder),
              ),
              child: RichText(
                text: TextSpan(
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: kTextSecondary,
                        height: 1.55,
                      ),
                  children: _highlightTranslationSpans(
                    studentTranslation,
                    result.deductions,
                  ),
                ),
              ),
            ),
            if (result.deductions.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('Deductions',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final deduction in result.deductions) ...[
                _TranslationDeductionTile(deduction: deduction),
                const SizedBox(height: 8),
              ],
            ],
            const SizedBox(height: 14),
            Text('Suggested Translation',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              result.suggestedTranslation,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: kTextPrimary,
                    height: 1.45,
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: isGeneratingSimilar ? null : onTrySimilar,
                icon: Icon(
                  isGeneratingSimilar
                      ? Icons.hourglass_top_rounded
                      : Icons.auto_awesome_rounded,
                ),
                label: Text(
                  isGeneratingSimilar
                      ? 'Generating...'
                      : 'Try Similar Sentence (舉一反三)',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TranslationDeductionTile extends StatelessWidget {
  const _TranslationDeductionTile({required this.deduction});

  final TranslationDeductionResult deduction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kDangerRed.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDangerRed.withOpacity(0.32)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '-${deduction.points.toStringAsFixed(1)}',
            style: const TextStyle(
              color: kDangerRed,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${deduction.errorType}: ${deduction.explanation}',
              style: const TextStyle(color: kTextSecondary, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

List<TextSpan> _highlightTranslationSpans(
  String text,
  List<TranslationDeductionResult> deductions,
) {
  if (text.isEmpty) return const [TextSpan(text: '')];
  final ranges = <({int start, int end})>[];
  final lower = text.toLowerCase();
  for (final deduction in deductions) {
    final target = deduction.errorText.trim();
    if (target.isEmpty) continue;
    final start = lower.indexOf(target.toLowerCase());
    if (start >= 0) {
      ranges.add((start: start, end: start + target.length));
    }
  }
  ranges.sort((a, b) => a.start.compareTo(b.start));
  final spans = <TextSpan>[];
  var cursor = 0;
  for (final range in ranges) {
    if (range.start < cursor) continue;
    if (range.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, range.start)));
    }
    spans.add(
      TextSpan(
        text: text.substring(range.start, range.end),
        style: const TextStyle(
          color: kDangerRed,
          fontWeight: FontWeight.w900,
          decoration: TextDecoration.underline,
        ),
      ),
    );
    cursor = range.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return spans;
}

class MixedQuestionScreen extends StatefulWidget {
  const MixedQuestionScreen({super.key});

  @override
  State<MixedQuestionScreen> createState() => _MixedQuestionScreenState();
}

class _MixedQuestionScreenState extends State<MixedQuestionScreen> {
  static final Uri _generateEndpoint =
      AppConfig.apiUri('/generate/mixed-questions');
  static final Uri _evaluateEndpoint =
      AppConfig.apiUri('/evaluate/mixed-answer');

  final Map<int, int> _selectedMcq = <int, int>{};
  final Map<int, TextEditingController> _answerControllers =
      <int, TextEditingController>{};
  final Map<int, MixedShortFeedback> _feedback = <int, MixedShortFeedback>{};
  final Set<int> _evaluating = <int>{};
  MixedQuestionSet? _set;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadSet();
  }

  @override
  void dispose() {
    for (final controller in _answerControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final set = _set;
    final isTablet = isTabletLayout(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Mixed Questions Sandbox')),
      body: SafeArea(
        child: _buildBody(set, isTablet),
      ),
    );
  }

  Widget _buildBody(MixedQuestionSet? set, bool isTablet) {
    if (_isLoading) {
      return const AppPage(
        children: [
          PageIntro(
            icon: Icons.dashboard_customize_outlined,
            title: 'Mixed Questions',
            subtitle:
                'GSAT Questions 47-56: integrate Text A, Text B, choices, and short answers.',
          ),
          SizedBox(height: 16),
          ReadingSkeleton(),
        ],
      );
    }

    if (_errorMessage != null) {
      return AppPage(
        children: [
          const PageIntro(
            icon: Icons.dashboard_customize_outlined,
            title: 'Mixed Questions',
            subtitle:
                'GSAT Questions 47-56: integrate Text A, Text B, choices, and short answers.',
          ),
          const SizedBox(height: 16),
          UnifiedErrorState(
            message: _errorMessage!,
            title: 'Mixed set needs a refresh',
            onRetry: _loadSet,
          ),
        ],
      );
    }

    if (set == null) return const AppPage(children: []);

    final texts = _MixedTextsPanel(set: set);
    final questions = _MixedQuestionsPanel(
      set: set,
      selectedMcq: _selectedMcq,
      answerControllers: _answerControllers,
      feedback: _feedback,
      evaluating: _evaluating,
      onSelectMcq: _selectMcq,
      onEvaluate: _evaluateShortAnswer,
    );

    if (isTablet) {
      return _ResponsiveBackdrop(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 8, 24),
                child: SingleChildScrollView(child: texts),
              ),
            ),
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 18, 24),
                child: SingleChildScrollView(child: questions),
              ),
            ),
          ],
        ),
      );
    }

    return AppPage(
      children: [
        const PageIntro(
          icon: Icons.dashboard_customize_outlined,
          title: 'Mixed Questions',
          subtitle:
              'GSAT Questions 47-56: integrate Text A, Text B, choices, and short answers.',
        ),
        const SizedBox(height: 16),
        texts,
        const SizedBox(height: 16),
        questions,
      ],
    );
  }

  Future<void> _loadSet() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _selectedMcq.clear();
      _feedback.clear();
    });

    try {
      final response = await _authenticatedPost(
        _generateEndpoint,
        body: jsonEncode({
          'topic':
              'Taiwan education, technology, youth culture, and exam preparation',
          'difficulty': 'GSAT',
        }),
      ).timeout(const Duration(seconds: 45));
      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final set = MixedQuestionSet.fromJson(_decodeJsonObject(response.body));
        for (final question in set.shortAnswer) {
          _answerControllers.putIfAbsent(
            question.number,
            () => TextEditingController(),
          );
        }
        setState(() {
          _set = set;
          _isLoading = false;
        });
      } else {
        _throwIfAiQuotaExceeded(response);
        setState(() {
          _errorMessage = 'Generator returned ${response.statusCode}.';
          _isLoading = false;
        });
      }
    } on AiQuotaExceededException {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Daily AI generation limit reached.';
      });
      unawaited(_showAiQuotaBottomSheet(context));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Unable to generate mixed questions right now.';
      });
    }
  }

  void _selectMcq(int questionNumber, int optionIndex) {
    setState(() {
      _selectedMcq[questionNumber] = optionIndex;
    });
    unawaited(HapticFeedback.selectionClick());
  }

  Future<void> _evaluateShortAnswer(MixedShortQuestion question) async {
    final answer = _answerControllers[question.number]?.text.trim() ?? '';
    if (answer.isEmpty || _evaluating.contains(question.number)) return;

    setState(() {
      _evaluating.add(question.number);
    });

    try {
      final response = await _authenticatedPost(
        _evaluateEndpoint,
        body: jsonEncode({
          'question': question.question,
          'reference_answer': question.referenceAnswer,
          'student_answer': answer,
          'max_score': question.maxScore,
          'rubric': question.rubric,
        }),
      ).timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final feedback =
            MixedShortFeedback.fromJson(_decodeJsonObject(response.body));
        setState(() {
          _feedback[question.number] = feedback;
        });
        unawaited(HapticFeedback.mediumImpact());
      } else {
        _throwIfAiQuotaExceeded(response);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Evaluation failed with ${response.statusCode}.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } on AiQuotaExceededException {
      if (!mounted) return;
      unawaited(_showAiQuotaBottomSheet(context));
    } finally {
      if (mounted) {
        setState(() {
          _evaluating.remove(question.number);
        });
      }
    }
  }
}

class _MixedTextsPanel extends StatelessWidget {
  const _MixedTextsPanel({required this.set});

  final MixedQuestionSet set;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Dual Texts',
                    style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                if (set.metrics != null)
                  InferenceBadge(
                    totalTimeSeconds: set.metrics!.totalTimeSeconds,
                    tokensPerSecond: set.metrics!.tokensPerSecond,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _MixedTextBlock(title: 'Text A', text: set.textA),
            const SizedBox(height: 14),
            _MixedTextBlock(title: 'Text B', text: set.textB),
          ],
        ),
      ),
    );
  }
}

class _MixedTextBlock extends StatelessWidget {
  const _MixedTextBlock({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scale = tabletReadingTextScale(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.035),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kGlassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: kNeonGreen, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text(
            text,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: kTextSecondary,
                  height: 1.55,
                  fontSize:
                      (Theme.of(context).textTheme.bodyLarge?.fontSize ?? 16) *
                          scale,
                ),
          ),
        ],
      ),
    );
  }
}

class _MixedQuestionsPanel extends StatelessWidget {
  const _MixedQuestionsPanel({
    required this.set,
    required this.selectedMcq,
    required this.answerControllers,
    required this.feedback,
    required this.evaluating,
    required this.onSelectMcq,
    required this.onEvaluate,
  });

  final MixedQuestionSet set;
  final Map<int, int> selectedMcq;
  final Map<int, TextEditingController> answerControllers;
  final Map<int, MixedShortFeedback> feedback;
  final Set<int> evaluating;
  final void Function(int questionNumber, int optionIndex) onSelectMcq;
  final ValueChanged<MixedShortQuestion> onEvaluate;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Questions 47-56',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            for (final question in set.multipleChoice) ...[
              _MixedMcqCard(
                question: question,
                selectedIndex: selectedMcq[question.number],
                onSelect: (index) => onSelectMcq(question.number, index),
              ),
              const SizedBox(height: 14),
            ],
            for (final question in set.shortAnswer) ...[
              _MixedShortAnswerCard(
                question: question,
                controller: answerControllers[question.number]!,
                feedback: feedback[question.number],
                isEvaluating: evaluating.contains(question.number),
                onEvaluate: () => onEvaluate(question),
              ),
              const SizedBox(height: 14),
            ],
          ],
        ),
      ),
    );
  }
}

class _MixedMcqCard extends StatelessWidget {
  const _MixedMcqCard({
    required this.question,
    required this.selectedIndex,
    required this.onSelect,
  });

  final MixedMcqQuestion question;
  final int? selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final answered = selectedIndex != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Q${question.number} · Multiple Choice',
          style:
              const TextStyle(color: kNeonGreen, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        Text(question.question, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        for (var index = 0; index < question.options.length; index++) ...[
          _TimeAttackOptionTile(
            label: String.fromCharCode(65 + index),
            text: question.options[index],
            isSelected: selectedIndex == index,
            isLocked: false,
            onTap: () => onSelect(index),
          ),
          if (index != question.options.length - 1) const SizedBox(height: 8),
        ],
        if (answered) ...[
          const SizedBox(height: 8),
          _InlineStatusPill(
            icon: selectedIndex == question.correctIndex
                ? Icons.check_circle_rounded
                : Icons.tips_and_updates_outlined,
            message: selectedIndex == question.correctIndex
                ? 'Correct. ${question.explanation}'
                : 'Review: ${question.explanation}',
            color: selectedIndex == question.correctIndex
                ? kNeonGreen
                : kElectricBlue,
          ),
        ],
      ],
    );
  }
}

class _MixedShortAnswerCard extends StatelessWidget {
  const _MixedShortAnswerCard({
    required this.question,
    required this.controller,
    required this.feedback,
    required this.isEvaluating,
    required this.onEvaluate,
  });

  final MixedShortQuestion question;
  final TextEditingController controller;
  final MixedShortFeedback? feedback;
  final bool isEvaluating;
  final VoidCallback onEvaluate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kSurfaceGlassStrong,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kGlassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Q${question.number} · Short Answer 簡答題',
            style: const TextStyle(
                color: kElectricBlue, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          Text(question.question,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText:
                  'Write a concise answer using evidence from both texts...',
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: isEvaluating ? null : onEvaluate,
              icon: Icon(isEvaluating
                  ? Icons.hourglass_top_rounded
                  : Icons.fact_check_rounded),
              label:
                  Text(isEvaluating ? 'Evaluating...' : 'Check Partial Credit'),
            ),
          ),
          if (feedback != null) ...[
            const SizedBox(height: 12),
            _MixedFeedbackCard(feedback: feedback!),
          ],
        ],
      ),
    );
  }
}

class _MixedFeedbackCard extends StatelessWidget {
  const _MixedFeedbackCard({required this.feedback});

  final MixedShortFeedback feedback;

  @override
  Widget build(BuildContext context) {
    final ratio =
        feedback.maxScore == 0 ? 0.0 : feedback.score / feedback.maxScore;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kNeonGreen.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kNeonGreen.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${feedback.score}/${feedback.maxScore} partial credit',
                style: const TextStyle(
                    color: kNeonGreen, fontWeight: FontWeight.w900),
              ),
              const Spacer(),
              if (feedback.metrics != null)
                InferenceBadge(
                  totalTimeSeconds: feedback.metrics!.totalTimeSeconds,
                  tokensPerSecond: feedback.metrics!.tokensPerSecond,
                ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: ratio.clamp(0.0, 1.0).toDouble(),
              backgroundColor: Colors.white.withOpacity(0.08),
              valueColor: const AlwaysStoppedAnimation<Color>(kNeonGreen),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            feedback.feedback,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: kTextSecondary,
                  height: 1.4,
                ),
          ),
        ],
      ),
    );
  }
}

class _InlineStatusPill extends StatelessWidget {
  const _InlineStatusPill({
    required this.icon,
    required this.message,
    required this.color,
  });

  final IconData icon;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.36)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              message,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w900,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class DiagnosticScreen extends StatefulWidget {
  const DiagnosticScreen({super.key});

  @override
  State<DiagnosticScreen> createState() => _DiagnosticScreenState();
}

class _DiagnosticScreenState extends State<DiagnosticScreen> {
  static final Uri _uploadEndpoint = AppConfig.apiUri('/upload/exam');
  static const Duration _uploadTimeout = Duration(seconds: 90);

  final ImagePicker _picker = ImagePicker();
  XFile? _selectedImage;
  bool _isUploading = false;
  String? _errorMessage;
  String? _analysisResult;
  List<CorrectedMistake> _correctedMistakes = const [];
  int _expansionQuizCount = 0;
  String? _expansionJobId;
  String? _expansionJobStatus;
  PerformanceMetrics? _diagnosticMetrics;

  @override
  Widget build(BuildContext context) {
    return AppPage(
      children: [
        const PageIntro(
          icon: Icons.psychology_alt_rounded,
          title: '診斷中心',
          subtitle: '上傳考卷、找出弱點，讓 AI 建立個人化複習計畫。',
        ),
        const SizedBox(height: 18),
        ActionPanel(
          icon: Icons.timer_outlined,
          title: '完整學測模擬考',
          description: '以 100 分鐘限時完成閱讀、文法與寫作，練習正式考試節奏。',
          buttonLabel: '開始模擬考',
          heroTag: 'time-attack-simulator-flow',
          onPressed: () => context.push('/exam-simulator'),
        ),
        const SizedBox(height: 16),
        ActionPanel(
          icon: Icons.quiz_outlined,
          title: '文法測驗',
          description: '產生符合學測難度的適性文法題，作答後立即查看解析。',
          buttonLabel: '開始測驗',
          heroTag: 'grammar-quiz-flow',
          onPressed: () => context.push('/grammar-quiz'),
        ),
        const SizedBox(height: 16),
        ActionPanel(
          icon: Icons.fact_check_outlined,
          title: '錯題本',
          description: '集中複習曾答錯的文法觀念，並用 AI 救贖挑戰重新攻克。',
          buttonLabel: '開啟錯題本',
          heroTag: 'error-ledger-flow',
          onPressed: () => context.push('/error-ledger'),
        ),
        const SizedBox(height: 16),
        ActionPanel(
          icon: Icons.account_tree_outlined,
          title: '篇章結構訓練',
          description: '拖曳關鍵句回正確段落，練習判斷文章脈絡與銜接。',
          buttonLabel: '開始篇章結構',
          heroTag: 'discourse-training-flow',
          onPressed: () => context.push('/discourse'),
        ),
        const SizedBox(height: 16),
        ActionPanel(
          icon: Icons.dashboard_customize_outlined,
          title: '混合題訓練',
          description: '練習雙文本、選擇題與可獲部分分數的簡答題。',
          buttonLabel: '開始混合題',
          heroTag: 'mixed-questions-flow',
          onPressed: () => context.push('/mixed-questions'),
        ),
        const SizedBox(height: 16),
        ActionPanel(
          icon: Icons.translate_rounded,
          title: '中翻英練習',
          description: '依學測標準嚴格扣分，並標示需要修正的字詞。',
          buttonLabel: '開始中翻英',
          heroTag: 'translation-practice-flow',
          onPressed: () => context.push('/translation-practice'),
        ),
        const SizedBox(height: 16),
        ActionPanel(
          icon: Icons.extension_rounded,
          title: '動態文意選填',
          description: '將學測高頻片語與搭配詞拖入正確空格。',
          buttonLabel: '開始文意選填',
          heroTag: 'cloze-practice-flow',
          onPressed: () => context.push('/cloze-practice'),
        ),
        const SizedBox(height: 16),
        ActionPanel(
          icon: Icons.upgrade_rounded,
          title: '句子升級',
          description: '使用進階句型改寫基礎句，提升學測英文寫作表現。',
          buttonLabel: '開始句子升級',
          heroTag: 'sentence-level-up-flow',
          onPressed: () => context.push('/sentence-level-up'),
        ),
        const SizedBox(height: 16),
        CleanCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '考卷圖片',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  '請拍攝清楚照片或從相簿選取圖片，並確認題目與作答都能辨識。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: kTextTertiary,
                        height: 1.4,
                      ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isUploading
                            ? null
                            : () => _pickImage(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('相機'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isUploading
                            ? null
                            : () => _pickImage(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('相簿'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (_selectedImage != null) ...[
          const SizedBox(height: 16),
          _ImagePreviewCard(image: _selectedImage!),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _isUploading ? null : _submitForAnalysis,
            icon: const Icon(Icons.auto_awesome_rounded),
            label: Text(
              _isUploading ? '分析中...' : '送出 AI 分析',
            ),
          ),
        ],
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          UnifiedErrorState(
            message: _errorMessage!,
            title: '診斷暫時無法完成',
            onRetry:
                _selectedImage == null ? _clearMessages : _submitForAnalysis,
          ),
        ],
        if (_analysisResult != null) ...[
          const SizedBox(height: 16),
          _DiagnosticAnalysisCard(
            result: _analysisResult!,
            metrics: _diagnosticMetrics,
            mistakes: _correctedMistakes,
            expansionQuizCount: _expansionQuizCount,
            expansionJobId: _expansionJobId,
            expansionJobStatus: _expansionJobStatus,
          ),
        ],
        if (_isUploading) ...[
          const SizedBox(height: 16),
          const _AnalyzingPaperCard(),
        ],
      ],
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    _clearMessages();

    try {
      final image = await _picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1800,
      );

      if (!mounted || image == null) return;

      setState(() {
        _selectedImage = image;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _permissionMessage(source, error);
      });
      if (source == ImageSource.camera) {
        unawaited(_offerGalleryFallback());
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Unable to open ${source == ImageSource.camera ? 'camera' : 'gallery'}. Please try again.';
      });
    }
  }

  Future<void> _offerGalleryFallback() async {
    if (!mounted) return;
    final useGallery = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('相機目前無法使用'),
        content: const Text('要改從相簿選取考卷圖片嗎？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('開啟相簿'),
          ),
        ],
      ),
    );
    if (useGallery == true && mounted) {
      await _pickImage(ImageSource.gallery);
    }
  }

  Future<void> _submitForAnalysis() async {
    final image = _selectedImage;
    if (image == null) {
      setState(() {
        _errorMessage = 'Please choose or take an image before submitting.';
      });
      return;
    }

    setState(() {
      _isUploading = true;
      _errorMessage = null;
      _analysisResult = null;
      _correctedMistakes = const [];
      _expansionQuizCount = 0;
      _expansionJobId = null;
      _expansionJobStatus = null;
      _diagnosticMetrics = null;
    });

    try {
      final request = _authenticatedMultipartRequest('POST', _uploadEndpoint)
        ..files.add(
          http.MultipartFile.fromBytes(
            'exam_image',
            await image.readAsBytes(),
            filename: image.name,
          ),
        );

      final response = await request.send().timeout(_uploadTimeout);
      final responseBody = await response.stream.bytesToString();

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = _decodeJsonObject(responseBody);
        final rawMistakes = data['corrected_mistakes'];
        final mistakes = rawMistakes is List
            ? rawMistakes
                .whereType<Map>()
                .map((item) =>
                    CorrectedMistake.fromJson(Map<String, dynamic>.from(item)))
                .toList()
            : <CorrectedMistake>[];
        setState(() {
          _analysisResult = _stringValue(
            data,
            ['analysis', 'feedback', 'result', 'message'],
            fallback:
                'Exam uploaded successfully. AI analysis is starting now.',
          );
          _correctedMistakes = mistakes;
          _expansionQuizCount =
              PerformanceMetrics._asInt(data['expansion_quiz_count']);
          _expansionJobId = _nullableString(data['expansion_job_id']);
          _expansionJobStatus = _nullableString(data['expansion_job_status']);
          _diagnosticMetrics = PerformanceMetrics.maybeFromResponse(data);
        });
        final jobId = _nullableString(data['expansion_job_id']);
        final jobStatus = _nullableString(data['expansion_job_status']);
        if (jobId != null &&
            jobId.isNotEmpty &&
            jobStatus != 'completed' &&
            jobStatus != 'failed') {
          unawaited(_pollExpansionJob(jobId, jobStatus ?? 'queued'));
        }
      } else if (_isAiQuotaLimitResponse(
        http.Response(responseBody, response.statusCode),
      )) {
        setState(() {
          _errorMessage = 'Daily AI generation limit reached.';
        });
        unawaited(_showAiQuotaBottomSheet(context));
      } else {
        setState(() {
          _errorMessage =
              'Upload failed with status ${response.statusCode}. Please try again.';
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'The upload timed out. Check your connection and try again.';
      });
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Cannot reach the analysis server. Make sure the backend is running.';
      });
    } on AiQuotaExceededException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Daily AI generation limit reached.';
      });
      unawaited(_showAiQuotaBottomSheet(context));
    } on http.ClientException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Network request failed: ${error.message}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Something went wrong during upload. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  Future<void> _pollExpansionJob(String jobId, String initialStatus) async {
    try {
      final completed = await const BackgroundJobPoller(
        maxAttempts: 45,
      ).waitForCompletion(
        initialJob: {'id': jobId, 'status': initialStatus},
        onStatus: (status) {
          if (!mounted) return;
          setState(() => _expansionJobStatus = status);
        },
        fetch: (id) async {
          final response =
              await _authenticatedGet(AppConfig.apiUri('/jobs/$id'));
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw StateError('Expansion job polling failed.');
          }
          return _decodeJsonObject(response.body);
        },
      );
      if (!mounted) return;
      final result = completed['result'];
      final resultMap = result is Map<String, dynamic>
          ? result
          : result is Map
              ? Map<String, dynamic>.from(result)
              : const <String, dynamic>{};
      final generatedCount = PerformanceMetrics._asInt(
        resultMap['created_count'] ?? resultMap['question_count'],
      );
      setState(() {
        _expansionJobStatus = 'completed';
        if (generatedCount > _expansionQuizCount) {
          _expansionQuizCount = generatedCount;
        }
      });
    } on BackgroundJobFailed catch (error) {
      if (!mounted) return;
      setState(() {
        _expansionJobStatus = 'failed';
        _errorMessage =
            'Expansion question generation failed: ${error.message}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _expansionJobStatus = 'retry needed';
      });
    }
  }

  void _clearMessages() {
    setState(() {
      _errorMessage = null;
      _analysisResult = null;
      _correctedMistakes = const [];
      _expansionQuizCount = 0;
      _expansionJobId = null;
      _expansionJobStatus = null;
      _diagnosticMetrics = null;
    });
  }

  String _permissionMessage(ImageSource source, PlatformException error) {
    final isCamera = source == ImageSource.camera;
    final code = error.code.toLowerCase();

    if (code.contains('denied') || code.contains('restricted')) {
      return isCamera
          ? '相機權限遭拒，請到系統設定開啟權限，或改從相簿選取。'
          : '相簿權限遭拒，請到系統設定開啟照片存取權限。';
    }

    return error.message ??
        'Unable to access ${isCamera ? 'camera' : 'gallery'}. Please try again.';
  }
}

class _ImagePreviewCard extends StatelessWidget {
  const _ImagePreviewCard({required this.image});

  final XFile image;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: FutureBuilder(
              future: image.readAsBytes(),
              builder: (context, snapshot) {
                final bytes = snapshot.data;
                if (bytes == null) return const ReadingSkeleton();
                return Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  width: double.infinity,
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const Icon(Icons.description_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    image.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.message,
    required this.icon,
    required this.color,
    required this.backgroundColor,
  });

  final String message;
  final IconData icon;
  final Color color;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: backgroundColor.withOpacity(0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.38)),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.08),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiagnosticAnalysisCard extends StatelessWidget {
  const _DiagnosticAnalysisCard({
    required this.result,
    required this.metrics,
    required this.mistakes,
    required this.expansionQuizCount,
    required this.expansionJobId,
    required this.expansionJobStatus,
  });

  final String result;
  final PerformanceMetrics? metrics;
  final List<CorrectedMistake> mistakes;
  final int expansionQuizCount;
  final String? expansionJobId;
  final String? expansionJobStatus;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'AI Diagnostic Result',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              result,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.4,
                    color: kTextSecondary,
                  ),
            ),
            if (mistakes.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Corrected Mistakes',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              for (final mistake in mistakes) ...[
                _CorrectedMistakeTile(mistake: mistake),
                const SizedBox(height: 10),
              ],
            ],
            if (expansionQuizCount > 0) ...[
              const SizedBox(height: 6),
              _InlineStatusPill(
                icon: Icons.next_plan_outlined,
                message:
                    '$expansionQuizCount 舉一反三 questions generated for tomorrow.',
                color: kElectricBlue,
              ),
            ],
            if (expansionJobId != null && expansionQuizCount == 0) ...[
              const SizedBox(height: 6),
              _InlineStatusPill(
                icon: Icons.cloud_sync_outlined,
                message: expansionJobStatus == 'completed'
                    ? '舉一反三練習已排入明日任務。'
                    : '舉一反三題目正在背景建立，明天會出現在首頁。',
                color: kElectricBlue,
              ),
            ],
            if (metrics != null) ...[
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: InferenceBadge(
                  totalTimeSeconds: metrics!.totalTimeSeconds,
                  tokensPerSecond: metrics!.tokensPerSecond,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CorrectedMistakeTile extends StatelessWidget {
  const _CorrectedMistakeTile({required this.mistake});

  final CorrectedMistake mistake;

  @override
  Widget build(BuildContext context) {
    final label = mistake.grammarConcept ?? mistake.vocabWord ?? 'exam_mistake';
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      collapsedIconColor: kTextSecondary,
      iconColor: kNeonGreen,
      title: Text(
        mistake.originalQuestion,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: kTextPrimary,
          fontWeight: FontWeight.w900,
        ),
      ),
      subtitle: Text(
        label,
        style: const TextStyle(color: kTextTertiary),
      ),
      children: [
        _MistakeLine(
          label: 'Your answer',
          value: mistake.studentWrongAnswer ?? 'Unknown',
          color: kDangerRed,
        ),
        _MistakeLine(
          label: 'Correct answer',
          value: mistake.correctAnswer,
          color: kNeonGreen,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            mistake.explanation,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: kTextSecondary,
                  height: 1.45,
                ),
          ),
        ),
      ],
    );
  }
}

class _MistakeLine extends StatelessWidget {
  const _MistakeLine({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: kTextSecondary, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnalyzingPaperCard extends StatefulWidget {
  const _AnalyzingPaperCard();

  @override
  State<_AnalyzingPaperCard> createState() => _AnalyzingPaperCardState();
}

class _AnalyzingPaperCardState extends State<_AnalyzingPaperCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                return Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        kNeonGreen.withOpacity(0.08 + _controller.value * 0.12),
                    border: Border.all(
                      color: kNeonGreen
                          .withOpacity(0.35 + _controller.value * 0.35),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: kNeonGreen
                            .withOpacity(0.16 + _controller.value * 0.18),
                        blurRadius: 18 + _controller.value * 18,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.document_scanner_outlined,
                      color: kNeonGreen),
                );
              },
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Analyzing your paper...',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Scanning answers, grading mistakes, logging weak points, and generating 舉一反三 drills.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: kTextTertiary,
                          height: 1.35,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ReadingVocabScreen extends StatefulWidget {
  const ReadingVocabScreen({super.key});

  @override
  State<ReadingVocabScreen> createState() => _ReadingVocabScreenState();
}

class _ReadingVocabScreenState extends State<ReadingVocabScreen> {
  static final Uri _readingEndpoint = AppConfig.apiUri('/generate/reading');

  String _article = _sampleNewsArticle;
  PerformanceMetrics? _readingMetrics;
  bool _isGenerating = false;
  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    return AppPage(
      children: [
        const PageIntro(
          icon: Icons.translate_rounded,
          title: '閱讀與單字',
          subtitle: '點選文章中的任何英文單字，即可加入個人單字庫。',
        ),
        const SizedBox(height: 18),
        CleanCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        'How Small Daily Habits Shape Better Learning',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (_readingMetrics != null) ...[
                      const SizedBox(width: 10),
                      InferenceBadge(
                        totalTimeSeconds: _readingMetrics!.totalTimeSeconds,
                        tokensPerSecond: _readingMetrics!.tokensPerSecond,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: const [
                    Chip(label: Text('Education')),
                    Chip(label: Text('GSAT Level 4')),
                    Chip(label: Text('5 min')),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _isGenerating ? null : _generateReadingPassage,
                      icon: Icon(
                        _isGenerating
                            ? Icons.hourglass_top_rounded
                            : Icons.auto_awesome_outlined,
                      ),
                      label: Text(
                        _isGenerating ? '文章產生中...' : '產生 AI 閱讀文章',
                      ),
                    ),
                    PassageAudioButton(text: _article),
                  ],
                ),
                const SizedBox(height: 16),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  child: _isGenerating
                      ? const ReadingSkeleton(key: ValueKey('reading-skeleton'))
                      : TappableReadingPassage(
                          key: ValueKey(_article.hashCode),
                          article: _article,
                        ),
                ),
              ],
            ),
          ),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          UnifiedErrorState(
            message: _errorMessage!,
            title: 'Reading generator paused',
            onRetry: _generateReadingPassage,
          ),
        ],
      ],
    );
  }

  Future<void> _generateReadingPassage() async {
    setState(() {
      _isGenerating = true;
      _errorMessage = null;
      _readingMetrics = null;
    });

    try {
      final response = await _authenticatedPost(
        _readingEndpoint,
        body: jsonEncode({
          'topic': 'education and teen learning',
          'level': 'GSAT Level 4',
          'word_count': 350,
        }),
      ).timeout(const Duration(seconds: 20));

      if (!mounted) return;

      final data = _decodeJsonObject(response.body);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() {
          _article = _stringValue(
            data,
            ['article', 'passage', 'reading', 'response'],
            fallback: _article,
          );
          _readingMetrics = PerformanceMetrics.maybeFromResponse(data);
        });
      } else if (_isAiQuotaLimitResponse(response)) {
        setState(() {
          _errorMessage = 'Daily AI generation limit reached.';
        });
        unawaited(_showAiQuotaBottomSheet(context));
      } else {
        setState(() {
          _errorMessage =
              'Unable to generate a reading passage (${response.statusCode}).';
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Reading generation timed out. Please try again.';
      });
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Cannot reach the reading generator. Make sure the backend is running.';
      });
    } on AiQuotaExceededException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Daily AI generation limit reached.';
      });
      unawaited(_showAiQuotaBottomSheet(context));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to generate the reading passage right now.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }
}

const String _sampleNewsArticle = '''
In many high schools, students are discovering that improvement does not always come from dramatic changes. Instead, it often begins with small decisions repeated every day. A student who reviews ten vocabulary words after breakfast, reads one short article on the bus, and writes three careful sentences before sleeping may build stronger English skills than a student who studies only before a major exam.

Teachers say this approach is especially useful for language learning because memory depends on repeated contact. When students meet a word in different contexts, they are more likely to understand its meaning and use it naturally. For example, the word "policy" may first appear in a textbook about government. Later, it may appear in a news story about school lunches, climate action, or technology companies. Each encounter gives the learner a clearer picture of how the word behaves.

Digital tools can also make practice more personal. An app can notice which words a student forgets, which reading topics feel difficult, and which grammar patterns appear in writing mistakes. With that information, the app can suggest focused exercises instead of asking every student to follow the same plan. This does not replace teachers. Rather, it gives teachers and students better evidence about what to practice next.

Still, experts warn that technology works best when students stay active. Simply tapping through answers is not enough. Learners need to pause, guess meanings from context, check translations, and use new words in their own sentences. They should also read about topics they care about, such as sports, music, science, travel, or social issues. Interest makes attention easier, and attention makes learning last longer.

For students preparing for important exams, the message is encouraging. Progress can feel slow, but it is not invisible. Every article read, every word reviewed, and every paragraph revised adds another layer of confidence. Over time, these quiet habits can turn English from a stressful subject into a practical tool for understanding the world.
''';

class TappableReadingPassage extends StatefulWidget {
  const TappableReadingPassage({super.key, required this.article});

  final String article;

  @override
  State<TappableReadingPassage> createState() => _TappableReadingPassageState();
}

class _TappableReadingPassageState extends State<TappableReadingPassage> {
  late List<_PassageToken> _tokens;
  final Set<String> _savedWords = <String>{};

  @override
  void initState() {
    super.initState();
    _tokens = _tokenize(widget.article);
  }

  @override
  void didUpdateWidget(covariant TappableReadingPassage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.article != widget.article) {
      _tokens = _tokenize(widget.article);
      _savedWords.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scale = tabletReadingTextScale(context);
    final textStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
          height: 1.45,
          color: kTextSecondary,
          fontSize:
              (Theme.of(context).textTheme.bodyLarge?.fontSize ?? 16) * scale,
        );

    return Wrap(
      spacing: 4,
      runSpacing: 8,
      children: [
        for (final token in _tokens)
          if (token.isWord)
            _TappableWord(
              text: token.text,
              isSaved: _savedWords.contains(token.normalizedWord),
              textStyle: textStyle,
              onTap: () => _saveWord(token.normalizedWord!),
            )
          else
            Text(token.text, style: textStyle),
      ],
    );
  }

  void _saveWord(String word) {
    setState(() {
      _savedWords.add(word);
    });

    unawaited(_submitSavedWord(word));

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Added $word to your 7000 vocabulary list'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<void> _submitSavedWord(String word) async {
    try {
      await _authenticatedPost(
        AppConfig.apiUri('/vocab/add'),
        body: jsonEncode({
          'word': word,
          'source_context': widget.article.length > 260
              ? widget.article.substring(0, 260)
              : widget.article,
        }),
      ).timeout(const Duration(seconds: 8));
    } catch (_) {
      // The UI stays instant; the Home review deck can still fall back to mocks.
    }
  }

  List<_PassageToken> _tokenize(String article) {
    final tokens = <_PassageToken>[];
    final wordPattern = RegExp(r"[A-Za-z]+(?:[-'][A-Za-z]+)?");
    final chunks = article.trim().split(RegExp(r'\s+'));

    for (final chunk in chunks) {
      final match = wordPattern.firstMatch(chunk);
      tokens.add(
        _PassageToken(
          chunk,
          normalizedWord: match?.group(0)?.toLowerCase(),
        ),
      );
    }

    return tokens;
  }
}

class _TappableWord extends StatelessWidget {
  const _TappableWord({
    required this.text,
    required this.isSaved,
    required this.textStyle,
    required this.onTap,
  });

  final String text;
  final bool isSaved;
  final TextStyle? textStyle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        decoration: BoxDecoration(
          color: isSaved ? colorScheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          style: textStyle?.copyWith(
            color: isSaved ? colorScheme.onPrimaryContainer : textStyle?.color,
            fontWeight: isSaved ? FontWeight.w800 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _PassageToken {
  const _PassageToken(this.text, {this.normalizedWord});

  final String text;
  final String? normalizedWord;

  bool get isWord => normalizedWord != null;
}

class WritingScores {
  const WritingScores({
    required this.content,
    required this.organization,
    required this.grammar,
    required this.vocabulary,
  });

  final double content;
  final double organization;
  final double grammar;
  final double vocabulary;

  factory WritingScores.fromJson(Map<String, dynamic> json) => WritingScores(
        content: PerformanceMetrics._asDouble(json['content']),
        organization: PerformanceMetrics._asDouble(json['organization']),
        grammar: PerformanceMetrics._asDouble(json['grammar']),
        vocabulary: PerformanceMetrics._asDouble(json['vocabulary']),
      );
}

class WritingCorrectionData {
  const WritingCorrectionData({
    required this.category,
    required this.originalSentence,
    required this.correctedSentence,
    required this.reason,
  });

  final String category;
  final String originalSentence;
  final String correctedSentence;
  final String reason;

  factory WritingCorrectionData.fromJson(Map<String, dynamic> json) {
    return WritingCorrectionData(
      category: _stringFromAny(json['category'], fallback: 'Language'),
      originalSentence: _stringFromAny(
        json['original_sentence'],
        fallback: _stringFromAny(json['error_text'],
            fallback: 'Original text unavailable'),
      ),
      correctedSentence: _stringFromAny(
        json['corrected_sentence'],
        fallback: 'No replacement suggested.',
      ),
      reason: _stringFromAny(json['reason'], fallback: 'Review this usage.'),
    );
  }
}

class WritingVocabularyAlternativeData {
  const WritingVocabularyAlternativeData({
    required this.original,
    required this.advanced,
    required this.usageNote,
  });

  final String original;
  final String advanced;
  final String usageNote;

  factory WritingVocabularyAlternativeData.fromJson(Map<String, dynamic> json) {
    return WritingVocabularyAlternativeData(
      original: _stringFromAny(json['original'], fallback: 'word'),
      advanced: _stringFromAny(json['advanced'], fallback: 'alternative'),
      usageNote: _stringFromAny(json['usage_note'], fallback: ''),
    );
  }
}

class WritingEvaluationData {
  const WritingEvaluationData({
    required this.totalScore,
    required this.maxScore,
    required this.scores,
    required this.corrections,
    required this.spellingIssues,
    required this.strengths,
    required this.priorityImprovements,
    required this.suggestedTemplate,
    required this.vocabularyAlternatives,
    required this.demonstration,
    required this.rubricVersion,
  });

  final double totalScore;
  final double maxScore;
  final WritingScores scores;
  final List<WritingCorrectionData> corrections;
  final List<WritingCorrectionData> spellingIssues;
  final List<String> strengths;
  final List<String> priorityImprovements;
  final List<String> suggestedTemplate;
  final List<WritingVocabularyAlternativeData> vocabularyAlternatives;
  final String demonstration;
  final String rubricVersion;

  factory WritingEvaluationData.fromJson(Map<String, dynamic> json) {
    final scoresJson = json['scores'];
    List<WritingCorrectionData> correctionsFrom(String key) {
      final raw = json[key];
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((item) =>
              WritingCorrectionData.fromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false);
    }

    List<String> stringsFrom(String key) {
      final raw = json[key];
      if (raw is! List) return const [];
      return raw
          .map((item) => item.toString())
          .where((item) => item.trim().isNotEmpty)
          .toList();
    }

    final rawAlternatives = json['advanced_vocabulary_alternatives'];
    final parsedMaxScore = PerformanceMetrics._asDouble(json['max_score']);
    return WritingEvaluationData(
      totalScore: PerformanceMetrics._asDouble(json['total_score']),
      maxScore: parsedMaxScore > 0 ? parsedMaxScore : 20,
      scores: WritingScores.fromJson(
        scoresJson is Map ? Map<String, dynamic>.from(scoresJson) : const {},
      ),
      corrections: correctionsFrom('corrections'),
      spellingIssues: correctionsFrom('spelling_and_punctuation_issues'),
      strengths: stringsFrom('strengths'),
      priorityImprovements: stringsFrom('priority_improvements'),
      suggestedTemplate: stringsFrom('suggested_template'),
      vocabularyAlternatives: rawAlternatives is List
          ? rawAlternatives
              .whereType<Map>()
              .map((item) => WritingVocabularyAlternativeData.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList(growable: false)
          : const [],
      demonstration: _stringFromAny(json['demonstration'], fallback: ''),
      rubricVersion:
          _stringFromAny(json['rubric_version'], fallback: 'gsat-writing-v1'),
    );
  }
}

enum GsatEssayType {
  standard('standard', 'Standard'),
  pictureDescription('picture_description', 'Picture Description (看圖說故事)'),
  chartAnalysis('chart_analysis', 'Chart Analysis (圖表分析)');

  const GsatEssayType(this.apiValue, this.label);

  final String apiValue;
  final String label;
}

enum _WritingImageTarget { prompt, handwritten }

class WritingScreen extends StatefulWidget {
  const WritingScreen({super.key});

  @override
  State<WritingScreen> createState() => _WritingScreenState();
}

class _WritingScreenState extends State<WritingScreen> {
  static final Uri _writingEndpoint = AppConfig.apiUri('/evaluate/writing');

  final TextEditingController _essayController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  GsatEssayType _essayType = GsatEssayType.standard;
  XFile? _promptImage;
  XFile? _handwrittenEssay;
  bool _isSubmitting = false;
  bool _showFeedback = false;
  bool _correctionsExpanded = false;
  String? _errorMessage;
  String? _writingFeedback;
  PerformanceMetrics? _writingMetrics;
  WritingEvaluationData? _writingEvaluation;

  bool get _canSubmit =>
      _essayController.text.trim().isNotEmpty || _handwrittenEssay != null;

  bool get _usesPromptImage => _essayType != GsatEssayType.standard;

  @override
  void initState() {
    super.initState();
    _essayController.addListener(_refreshSubmitState);
  }

  @override
  void dispose() {
    _essayController
      ..removeListener(_refreshSubmitState)
      ..dispose();
    super.dispose();
  }

  void _refreshSubmitState() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AppPage(
      children: [
        const PageIntro(
          icon: Icons.rate_review_rounded,
          title: '英文寫作',
          subtitle: '輸入作文或上傳手寫稿，取得 AI 評分、訂正與改寫建議。',
        ),
        const SizedBox(height: 18),
        CleanCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('作文類型', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                DropdownButtonFormField<GsatEssayType>(
                  value: _essayType,
                  isExpanded: true,
                  items: [
                    for (final type in GsatEssayType.values)
                      DropdownMenuItem(
                        value: type,
                        child: Text(type.label),
                      ),
                  ],
                  onChanged: _isSubmitting
                      ? null
                      : (type) {
                          if (type == null) return;
                          setState(() {
                            _essayType = type;
                            if (!_usesPromptImage) {
                              _promptImage = null;
                            }
                            _showFeedback = false;
                            _writingFeedback = null;
                            _writingMetrics = null;
                            _writingEvaluation = null;
                          });
                        },
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.assignment_outlined),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_usesPromptImage) ...[
          const SizedBox(height: 16),
          CleanCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _essayType == GsatEssayType.chartAnalysis
                            ? Icons.insert_chart_outlined_rounded
                            : Icons.image_search_outlined,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '題目圖片',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _essayType == GsatEssayType.chartAnalysis
                        ? '上傳這篇作文要分析的圖表或統計圖。'
                        : '上傳這篇作文要描述的題目圖片。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: kTextTertiary,
                          height: 1.4,
                        ),
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: _isSubmitting
                        ? null
                        : () =>
                            _showPhotoSourceSheet(_WritingImageTarget.prompt),
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(
                      _promptImage == null ? '上傳題目圖片' : '更換題目圖片',
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_promptImage != null) ...[
            const SizedBox(height: 16),
            _ImagePreviewCard(image: _promptImage!),
          ],
        ],
        const SizedBox(height: 16),
        CleanCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('輸入英文作文', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                TextField(
                  controller: _essayController,
                  minLines: 9,
                  maxLines: 16,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    hintText: '在此貼上或輸入符合學測格式的英文作文...',
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        CleanCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.draw_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '手寫作文',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '若作文寫在紙上，請上傳清楚、完整的照片。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: kTextTertiary,
                        height: 1.4,
                      ),
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: _isSubmitting
                      ? null
                      : () => _showPhotoSourceSheet(
                          _WritingImageTarget.handwritten),
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: Text(
                    _handwrittenEssay == null ? '上傳手寫作文照片' : '更換照片',
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_handwrittenEssay != null) ...[
          const SizedBox(height: 16),
          _ImagePreviewCard(image: _handwrittenEssay!),
        ],
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          _StatusBanner(
            message: _errorMessage!,
            icon: Icons.error_outline_rounded,
            color: const Color(0xFFC2410C),
            backgroundColor: const Color(0xFFFFF7ED),
          ),
        ],
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _isSubmitting || !_canSubmit ? null : _submitEssay,
          icon: _isSubmitting
              ? const Icon(Icons.hourglass_top_rounded)
              : const Icon(Icons.auto_awesome_rounded),
          label: Text(_isSubmitting ? '評分中...' : '送出 AI 評分'),
        ),
        if (_isSubmitting) ...[
          const SizedBox(height: 16),
          const GrammarSkeleton(),
        ],
        if (_showFeedback) ...[
          const SizedBox(height: 24),
          _WritingFeedbackResults(
            feedback: _writingFeedback,
            metrics: _writingMetrics,
            evaluation: _writingEvaluation!,
            correctionsExpanded: _correctionsExpanded,
            onCorrectionsExpansionChanged: (isExpanded) {
              setState(() {
                _correctionsExpanded = !isExpanded;
              });
            },
          ),
        ],
      ],
    );
  }

  Future<void> _showPhotoSourceSheet(_WritingImageTarget target) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('使用相機拍照'),
                  onTap: () => Navigator.of(context).pop(ImageSource.camera),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('從相簿選取'),
                  onTap: () => Navigator.of(context).pop(ImageSource.gallery),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (source != null) {
      await _pickWritingImage(source, target);
    }
  }

  Future<void> _pickWritingImage(
    ImageSource source,
    _WritingImageTarget target,
  ) async {
    setState(() {
      _errorMessage = null;
      _showFeedback = false;
      _writingMetrics = null;
      _writingFeedback = null;
      _writingEvaluation = null;
    });

    try {
      final image = await _picker.pickImage(
        source: source,
        imageQuality: 88,
        maxWidth: 1800,
      );

      if (!mounted || image == null) return;

      setState(() {
        if (target == _WritingImageTarget.prompt) {
          _promptImage = image;
        } else {
          _handwrittenEssay = image;
        }
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _writingPermissionMessage(source, target, error);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = target == _WritingImageTarget.prompt
            ? 'Unable to select the prompt image. Please try again.'
            : 'Unable to select the essay photo. Please try again.';
      });
    }
  }

  Future<void> _submitEssay() async {
    FocusScope.of(context).unfocus();
    final essayText = _essayController.text.trim();

    setState(() {
      _isSubmitting = true;
      _showFeedback = false;
      _errorMessage = null;
      _writingFeedback = null;
      _writingMetrics = null;
      _writingEvaluation = null;
    });

    try {
      late final int statusCode;
      late final String responseBody;

      if (_promptImage != null || _handwrittenEssay != null) {
        final request = _authenticatedMultipartRequest('POST', _writingEndpoint)
          ..fields['essay'] = essayText
          ..fields['essay_type'] = _essayType.apiValue;

        if (_promptImage != null) {
          request.files.add(
            http.MultipartFile.fromBytes(
              'prompt_image',
              await _promptImage!.readAsBytes(),
              filename: _promptImage!.name,
            ),
          );
        }

        if (_handwrittenEssay != null) {
          request.files.add(
            http.MultipartFile.fromBytes(
              'handwritten_essay',
              await _handwrittenEssay!.readAsBytes(),
              filename: _handwrittenEssay!.name,
            ),
          );
        }

        final streamedResponse = await request.send().timeout(
              const Duration(seconds: 45),
            );
        statusCode = streamedResponse.statusCode;
        responseBody = await streamedResponse.stream.bytesToString();
      } else {
        final response = await _authenticatedPost(
          _writingEndpoint,
          body: jsonEncode({
            'essay': essayText,
            'essay_type': _essayType.apiValue,
          }),
        ).timeout(const Duration(seconds: 30));
        statusCode = response.statusCode;
        responseBody = response.body;
      }

      if (!mounted) return;

      final data = _decodeJsonObject(responseBody);

      if (statusCode >= 200 && statusCode < 300) {
        final rawEvaluation = data['evaluation'];
        if (rawEvaluation is! Map) {
          throw const FormatException(
              'Writing response is missing evaluation data.');
        }
        final evaluation = WritingEvaluationData.fromJson(
          Map<String, dynamic>.from(rawEvaluation),
        );
        setState(() {
          _writingFeedback = _stringValue(
            data,
            ['feedback', 'result', 'analysis', 'message'],
            fallback:
                'Your essay was graded successfully. Review the score card and suggested revisions below.',
          );
          _writingMetrics = PerformanceMetrics.maybeFromResponse(data);
          _writingEvaluation = evaluation;
          _showFeedback = true;
          _correctionsExpanded = false;
        });
      } else if (_isAiQuotaLimitResponse(
          http.Response(responseBody, statusCode))) {
        setState(() {
          _errorMessage = 'Daily AI generation limit reached.';
        });
        unawaited(_showAiQuotaBottomSheet(context));
      } else {
        setState(() {
          _errorMessage = 'Writing evaluation failed with status $statusCode.';
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Writing evaluation timed out. Please try again.';
      });
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Cannot reach the writing evaluator. Make sure the backend is running.';
      });
    } on AiQuotaExceededException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Daily AI generation limit reached.';
      });
      unawaited(_showAiQuotaBottomSheet(context));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to evaluate your essay right now.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  String _writingPermissionMessage(
    ImageSource source,
    _WritingImageTarget target,
    PlatformException error,
  ) {
    final isCamera = source == ImageSource.camera;
    final targetName =
        target == _WritingImageTarget.prompt ? 'prompt image' : 'essay photo';
    final code = error.code.toLowerCase();

    if (code.contains('denied') || code.contains('restricted')) {
      return isCamera
          ? 'Camera permission was denied. Enable camera access in Settings to photograph your $targetName.'
          : 'Photo library permission was denied. Enable photo access in Settings to upload your $targetName.';
    }

    return error.message ??
        'Unable to access ${isCamera ? 'camera' : 'gallery'}. Please try again.';
  }
}

class _WritingFeedbackResults extends StatelessWidget {
  const _WritingFeedbackResults({
    required this.feedback,
    required this.metrics,
    required this.evaluation,
    required this.correctionsExpanded,
    required this.onCorrectionsExpansionChanged,
  });

  final String? feedback;
  final PerformanceMetrics? metrics;
  final WritingEvaluationData evaluation;
  final bool correctionsExpanded;
  final ValueChanged<bool> onCorrectionsExpansionChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('AI Feedback', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (feedback != null && feedback!.isNotEmpty) ...[
          _FeedbackSummaryCard(feedback: feedback!),
          const SizedBox(height: 16),
        ],
        _ScoreCard(evaluation: evaluation, metrics: metrics),
        const SizedBox(height: 16),
        _DetailedCorrectionsPanel(
          corrections: [
            ...evaluation.spellingIssues,
            ...evaluation.corrections
          ],
          isExpanded: correctionsExpanded,
          onExpansionChanged: onCorrectionsExpansionChanged,
        ),
        const SizedBox(height: 16),
        _SuggestedTemplateCard(
          steps: evaluation.suggestedTemplate,
          demonstration: evaluation.demonstration,
        ),
        const SizedBox(height: 16),
        _VocabularyAlternativesCard(
          alternatives: evaluation.vocabularyAlternatives,
        ),
      ],
    );
  }
}

class _FeedbackSummaryCard extends StatelessWidget {
  const _FeedbackSummaryCard({required this.feedback});

  final String feedback;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.smart_toy_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'AI Summary',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              feedback,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: kTextSecondary,
                    height: 1.45,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.evaluation, required this.metrics});

  final WritingEvaluationData evaluation;
  final PerformanceMetrics? metrics;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.emoji_events_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Text('Score Card',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text(
                  '${evaluation.totalScore.toStringAsFixed(1)}/${evaluation.maxScore.toStringAsFixed(0)}',
                  style: const TextStyle(
                    color: kNeonGreen,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _ScoreMetric(label: 'Content', score: evaluation.scores.content),
            _ScoreMetric(
                label: 'Organization', score: evaluation.scores.organization),
            _ScoreMetric(label: 'Grammar', score: evaluation.scores.grammar),
            _ScoreMetric(
                label: 'Vocabulary', score: evaluation.scores.vocabulary),
            if (metrics != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: InferenceBadge(
                  totalTimeSeconds: metrics!.totalTimeSeconds,
                  tokensPerSecond: metrics!.tokensPerSecond,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ScoreMetric extends StatelessWidget {
  const _ScoreMetric({required this.label, required this.score});

  final String label;
  final double score;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: score / 5,
                minHeight: 10,
                color: color,
                backgroundColor: kGlassBorder,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${score.toStringAsFixed(score % 1 == 0 ? 0 : 1)}/5',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailedCorrectionsPanel extends StatelessWidget {
  const _DetailedCorrectionsPanel({
    required this.corrections,
    required this.isExpanded,
    required this.onExpansionChanged,
  });

  final List<WritingCorrectionData> corrections;
  final bool isExpanded;
  final ValueChanged<bool> onExpansionChanged;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ExpansionPanelList(
        elevation: 0,
        expansionCallback: (index, expanded) => onExpansionChanged(expanded),
        expandedHeaderPadding: EdgeInsets.zero,
        children: [
          ExpansionPanel(
            isExpanded: isExpanded,
            canTapOnHeader: true,
            backgroundColor: kSurfaceGlassStrong,
            headerBuilder: (context, isExpanded) {
              return const ListTile(
                leading: Icon(Icons.fact_check_outlined),
                title: Text(
                  'Detailed Corrections',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              );
            },
            body: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: corrections.isEmpty
                  ? const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'No sentence-level corrections were needed.',
                        style: TextStyle(color: kTextSecondary),
                      ),
                    )
                  : Column(
                      children: [
                        for (final correction in corrections)
                          _CorrectionItem(
                            original: correction.originalSentence,
                            revised: correction.correctedSentence,
                            note:
                                '${correction.category}: ${correction.reason}',
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CorrectionItem extends StatelessWidget {
  const _CorrectionItem({
    required this.original,
    required this.revised,
    required this.note,
  });

  final String original;
  final String revised;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            original,
            style: const TextStyle(
              color: Color(0xFFB42318),
              decoration: TextDecoration.lineThrough,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            revised,
            style: const TextStyle(
              color: Color(0xFF047857),
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            note,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: kTextTertiary,
                  height: 1.35,
                ),
          ),
        ],
      ),
    );
  }
}

class _SuggestedTemplateCard extends StatelessWidget {
  const _SuggestedTemplateCard({
    required this.steps,
    required this.demonstration,
  });

  final List<String> steps;
  final String demonstration;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.view_agenda_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Text(
                  'Suggested Template',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (steps.isEmpty)
              const Text(
                'No template was returned for this essay.',
                style: TextStyle(color: kTextSecondary),
              )
            else
              for (var index = 0; index < steps.length; index++)
                _TemplateStep(
                  label: 'Step ${index + 1}',
                  text: steps[index],
                ),
            if (demonstration.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Model revision',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              Text(
                demonstration,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: kTextSecondary,
                      height: 1.45,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TemplateStep extends StatelessWidget {
  const _TemplateStep({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.4,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VocabularyAlternativesCard extends StatelessWidget {
  const _VocabularyAlternativesCard({required this.alternatives});

  final List<WritingVocabularyAlternativeData> alternatives;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_stories_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Advanced Vocabulary Alternatives',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (alternatives.isEmpty)
              const Text(
                'No vocabulary substitutions were suggested.',
                style: TextStyle(color: kTextSecondary),
              )
            else
              for (final alternative in alternatives)
                _VocabularyAlternative(
                  simple: alternative.original,
                  advanced: alternative.advanced,
                  usageNote: alternative.usageNote,
                ),
          ],
        ),
      ),
    );
  }
}

class _VocabularyAlternative extends StatelessWidget {
  const _VocabularyAlternative({
    required this.simple,
    required this.advanced,
    required this.usageNote,
  });

  final String simple;
  final String advanced;
  final String usageNote;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text(simple,
                      style: const TextStyle(color: kTextTertiary))),
              const Icon(Icons.arrow_forward_rounded, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(advanced,
                    style: const TextStyle(fontWeight: FontWeight.w900)),
              ),
            ],
          ),
          if (usageNote.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              usageNote,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: kTextTertiary),
            ),
          ],
        ],
      ),
    );
  }
}

class AppPage extends StatelessWidget {
  const AppPage({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.8, -0.9),
            radius: 1.1,
            colors: [
              Color(0x262F80ED),
              kAppBackground,
            ],
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
          children: children,
        ),
      ),
    );
  }
}

class _ResponsiveBackdrop extends StatelessWidget {
  const _ResponsiveBackdrop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(-0.8, -0.9),
          radius: 1.1,
          colors: [
            Color(0x262F80ED),
            kAppBackground,
          ],
        ),
      ),
      child: child,
    );
  }
}

class GreetingHeader extends StatelessWidget {
  const GreetingHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: kSurfaceGlassStrong,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kGlassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ready for today?',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: kTextPrimary,
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Finish your due reviews, read one article, and keep the streak alive.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: kTextSecondary,
                  height: 1.45,
                ),
          ),
        ],
      ),
    );
  }
}

class PageIntro extends StatelessWidget {
  const PageIntro({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: kNeonGreen.withOpacity(0.12),
          child: Icon(icon, color: kNeonGreen),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: kTextSecondary,
                      height: 1.4,
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
            ),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: kTextTertiary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.actionLabel,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (actionLabel != null)
                  TextButton(
                    onPressed: () {},
                    child: Text(actionLabel!),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

class DueItem extends StatelessWidget {
  const DueItem({super.key, required this.word, required this.meaning});

  final String word;
  final String meaning;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(word, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(meaning),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () {},
    );
  }
}

class CleanCard extends StatelessWidget {
  const CleanCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final isFocusMode = ref.watch(appModeControllerProvider).isFocus;
        final decoration = BoxDecoration(
          color: isFocusMode ? const Color(0xFF181818) : kSurfaceGlass,
          borderRadius: BorderRadius.circular(8),
          border:
              Border.all(color: isFocusMode ? Colors.white24 : kGlassBorder),
          boxShadow: isFocusMode
              ? const []
              : [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.28),
                    blurRadius: 28,
                    offset: const Offset(0, 18),
                  ),
                ],
        );

        final card = Container(decoration: decoration, child: child);
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: isFocusMode
              ? card
              : BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: card,
                ),
        );
      },
    );
  }
}

class ActionPanel extends StatelessWidget {
  const ActionPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.buttonLabel,
    required this.onPressed,
    this.heroTag,
  });

  final IconData icon;
  final String title;
  final String description;
  final String buttonLabel;
  final VoidCallback onPressed;
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final panel = CleanCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 34, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              description,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: kTextTertiary,
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onPressed,
              child: Text(buttonLabel),
            ),
          ],
        ),
      ),
    );

    if (heroTag == null) return panel;

    return Hero(
      tag: heroTag!,
      child: Material(
        color: Colors.transparent,
        child: panel,
      ),
    );
  }
}

class ArticleCard extends StatelessWidget {
  const ArticleCard({
    super.key,
    required this.category,
    required this.title,
    required this.level,
    required this.minutes,
    required this.words,
  });

  final String category;
  final String title;
  final String level;
  final String minutes;
  final List<String> words;

  @override
  Widget build(BuildContext context) {
    return CleanCard(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {},
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                category.toUpperCase(),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 8),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Row(
                children: [
                  Chip(label: Text(level)),
                  const SizedBox(width: 8),
                  Chip(
                    avatar: const Icon(Icons.timer_outlined, size: 18),
                    label: Text(minutes),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final word in words)
                    ActionChip(
                      label: Text(word),
                      avatar: const Icon(Icons.translate_rounded, size: 18),
                      onPressed: () => _showTranslation(context, word),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTranslation(BuildContext context, String word) {
    final translations = {
      'adapt': '適應；改編',
      'interactive': '互動的',
      'reliable': '可靠的',
      'urban': '都市的',
      'policy': '政策',
      'impact': '影響',
    };

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$word: ${translations[word] ?? 'Tap-to-translate'}'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

class FeedbackRow extends StatelessWidget {
  const FeedbackRow({super.key, required this.label, required this.score});

  final String label;
  final String score;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            score,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
