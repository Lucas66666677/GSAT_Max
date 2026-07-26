import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gsat_max/core/config/app_config.dart';
import 'package:gsat_max/core/services/background_job_poller.dart';
import 'package:gsat_max/core/services/purchase_service.dart';
import 'package:gsat_max/core/services/target_exam_date_service.dart';
import 'package:gsat_max/core/storage/mission_progress_store.dart';
import 'package:gsat_max/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    debugDefaultTargetPlatformOverride = null;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('AppConfig selects Android emulator host and desktop localhost', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(AppConfig.apiBaseUrl, 'http://10.0.2.2:8000');
    expect(AppConfig.apiUri('/health').host, '10.0.2.2');

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(AppConfig.apiBaseUrl, 'http://localhost:8000');
  });

  test('daily mission overrides persist locally and expire by day', () async {
    final preferences = await SharedPreferences.getInstance();
    final store = MissionProgressStore(preferences: preferences);
    final today = DateTime(2026, 7, 27, 21, 30);

    await store.setOverride(
      userId: 7,
      day: today,
      taskId: 41,
      completed: true,
    );
    await store.setOverride(
      userId: 7,
      day: today,
      taskId: 42,
      completed: false,
    );

    final restored = await MissionProgressStore(preferences: preferences)
        .readOverrides(userId: 7, day: today);
    expect(restored, <int, bool>{41: true, 42: false});
    expect(
      await store.readOverrides(
        userId: 7,
        day: today.add(const Duration(days: 1)),
      ),
      isEmpty,
    );

    await store.clearOverride(userId: 7, day: today, taskId: 41);
    expect(
      await store.readOverrides(userId: 7, day: today),
      <int, bool>{42: false},
    );
  });

  test('background job poller returns completion after queued states',
      () async {
    var fetchCount = 0;
    final poller = BackgroundJobPoller(
      pollInterval: Duration.zero,
      maxAttempts: 4,
      delay: (_) async {},
    );

    final result = await poller.waitForCompletion(
      initialJob: const {'id': 'job-1', 'status': 'queued'},
      fetch: (_) async {
        fetchCount += 1;
        return fetchCount == 1
            ? <String, dynamic>{'id': 'job-1', 'status': 'running'}
            : <String, dynamic>{
                'id': 'job-1',
                'status': 'completed',
                'result': {'question_count': 3},
              };
      },
    );

    expect(fetchCount, 2);
    expect(result['status'], 'completed');
    expect((result['result'] as Map)['question_count'], 3);
  });

  test('background job poller exposes failure and timeout', () async {
    final poller = BackgroundJobPoller(
      pollInterval: Duration.zero,
      maxAttempts: 2,
      delay: (_) async {},
    );
    await expectLater(
      poller.waitForCompletion(
        initialJob: const {
          'id': 'failed-job',
          'status': 'failed',
          'error_message': 'AI schema invalid',
        },
        fetch: (_) async => <String, dynamic>{},
      ),
      throwsA(
        isA<BackgroundJobFailed>()
            .having((error) => error.message, 'message', 'AI schema invalid'),
      ),
    );
    await expectLater(
      poller.waitForCompletion(
        initialJob: const {'id': 'slow-job', 'status': 'queued'},
        fetch: (_) async =>
            <String, dynamic>{'id': 'slow-job', 'status': 'queued'},
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('target exam date service sends and validates structured response',
      () async {
    final requested = DateTime(2027, 1, 23);
    Uri? capturedUri;
    Object? capturedBody;
    final result = await TargetExamDateService(
      endpoint: Uri.parse('http://localhost:8000/user/target-exam-date'),
    ).update(
      requestedDate: requested,
      send: (uri, body) async {
        capturedUri = uri;
        capturedBody = body;
        return http.Response(
          jsonEncode({'target_exam_date': '2027-01-23T00:00:00'}),
          200,
        );
      },
    );

    expect(capturedUri!.path, '/user/target-exam-date');
    expect(jsonDecode(capturedBody! as String)['target_exam_date'],
        requested.toIso8601String());
    expect(result, DateTime(2027, 1, 23));
  });

  test('auth restore rotates refresh token and keeps signed-in profile',
      () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'auth_access_token_v1': 'expired-access',
      'auth_refresh_token_v1': 'refresh-1',
    });
    final controller = AuthController(
      client: MockClient((request) async {
        expect(request.url.path, '/auth/refresh');
        expect(jsonDecode(request.body)['refresh_token'], 'refresh-1');
        return http.Response(jsonEncode(_authPayload()), 200);
      }),
      enablePostAuthSideEffects: false,
    );

    await _waitUntil(() => !controller.isInitializing);
    expect(controller.isLoggedIn, isTrue);
    expect(controller.token, 'access-2');
    expect(controller.userId, 17);
    expect(controller.hasCompletedOnboarding, isTrue);
    expect(controller.isPro, isTrue);
    expect(
      await const FlutterSecureStorage().read(key: 'auth_refresh_token_v1'),
      'refresh-2',
    );
    controller.dispose();
  });

  test('failed refresh clears secure tokens and returns signed-out state',
      () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'auth_access_token_v1': 'expired-access',
      'auth_refresh_token_v1': 'revoked-refresh',
    });
    final controller = AuthController(
      client: MockClient((_) async =>
          http.Response(jsonEncode({'detail': 'Refresh token revoked.'}), 401)),
      enablePostAuthSideEffects: false,
    );

    await _waitUntil(() => !controller.isInitializing);
    expect(controller.isLoggedIn, isFalse);
    expect(controller.token, isNull);
    expect(
      await const FlutterSecureStorage().read(key: 'auth_refresh_token_v1'),
      isNull,
    );
    controller.dispose();
  });

  test('transient refresh outage preserves cached offline login', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'auth_access_token_v1': 'cached-access',
      'auth_refresh_token_v1': 'cached-refresh',
      'auth_profile_v1': jsonEncode({
        'user_id': 17,
        'email': 'offline@example.com',
        'display_name': 'Offline Student',
        'current_streak': 4,
        'has_completed_onboarding': true,
        'is_pro': false,
      }),
    });
    final controller = AuthController(
      client: MockClient((_) async => http.Response(
          jsonEncode({'detail': 'Temporary backend outage.'}), 503)),
      enablePostAuthSideEffects: false,
    );

    await _waitUntil(() => !controller.isInitializing);
    expect(controller.isLoggedIn, isTrue);
    expect(controller.userId, 17);
    expect(controller.hasCompletedOnboarding, isTrue);
    expect(controller.currentStreak, 4);
    expect(
      await const FlutterSecureStorage().read(key: 'auth_refresh_token_v1'),
      'cached-refresh',
    );
    controller.dispose();
  });

  testWidgets('app startup router settles on login when no session exists',
      (tester) async {
    final auth = _StaticAuthController(signedIn: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authControllerProvider.overrideWith((ref) => auth)],
        child: const GsatEnglishApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('GSAT_Max'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('authenticated shell renders and switches all five core tabs',
      (tester) async {
    final auth = _StaticAuthController(signedIn: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authControllerProvider.overrideWith((ref) => auth)],
        child: const GsatEnglishApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    for (final label in ['首頁', '診斷', '閱讀', '寫作', '個人']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(HomeScreen), findsOneWidget);

    await _openTab(tester, '診斷');
    expect(find.byType(DiagnosticScreen), findsOneWidget);
    await _openTab(tester, '閱讀');
    expect(find.byType(ReadingVocabScreen), findsOneWidget);
    await _openTab(tester, '寫作');
    expect(find.byType(WritingScreen), findsOneWidget);
    await _openTab(tester, '個人');
    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('logout requires explicit confirmation', (tester) async {
    final auth = _StaticAuthController(signedIn: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authControllerProvider.overrideWith((ref) => auth)],
        child: const GsatEnglishApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('登出'));
    await tester.pumpAndSettle();

    expect(find.text('確定要登出嗎？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('five core tabs do not overflow on a small Android viewport',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = _StaticAuthController(signedIn: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authControllerProvider.overrideWith((ref) => auth)],
        child: const GsatEnglishApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);

    for (final label in ['診斷', '閱讀', '寫作', '個人']) {
      await _openTab(tester, label);
      expect(tester.takeException(), isNull, reason: '$label overflowed');
    }
  });

  group('paywall outcomes', () {
    testWidgets('successful purchase routes to profile', (tester) async {
      await _pumpPaywall(
        tester,
        const PurchaseFlowResult(
          PurchaseFlowStatus.purchased,
          'Purchased.',
        ),
      );
      await tester.tap(find.text(r'Subscribe to Pro ($4.99/mo)'));
      await tester.pumpAndSettle();
      expect(find.text('Profile destination'), findsOneWidget);
    });

    testWidgets('cancelled purchase stays on paywall without an error state',
        (tester) async {
      await _pumpPaywall(
        tester,
        const PurchaseFlowResult(
          PurchaseFlowStatus.cancelled,
          'Purchase cancelled. No charge was made.',
        ),
      );
      await tester.tap(find.text(r'Subscribe to Pro ($4.99/mo)'));
      await tester.pump();
      expect(find.byType(PaywallScreen), findsOneWidget);
      expect(
          find.text('Purchase cancelled. No charge was made.'), findsOneWidget);
    });

    testWidgets('failed purchase exposes the store error and stays on paywall',
        (tester) async {
      await _pumpPaywall(
        tester,
        const PurchaseFlowResult(
          PurchaseFlowStatus.failed,
          'Store account is unavailable.',
        ),
      );
      await tester.tap(find.text(r'Subscribe to Pro ($4.99/mo)'));
      await tester.pump();
      expect(find.byType(PaywallScreen), findsOneWidget);
      expect(find.text('Store account is unavailable.'), findsOneWidget);
    });
  });
}

Map<String, dynamic> _authPayload() => <String, dynamic>{
      'access_token': 'access-2',
      'refresh_token': 'refresh-2',
      'user_id': 17,
      'email': 'student@example.com',
      'display_name': 'Student',
      'current_streak': 3,
      'has_completed_onboarding': true,
      'is_pro': true,
    };

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('Condition did not become true during the test.');
}

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).last);
  await tester.pump(const Duration(milliseconds: 400));
}

class _StaticAuthController extends AuthController {
  _StaticAuthController({required this.signedIn})
      : super(
          client: MockClient((_) async => http.Response('{}', 503)),
          enablePostAuthSideEffects: false,
        );

  final bool signedIn;

  @override
  bool get isInitializing => false;

  @override
  bool get isLoggedIn => signedIn;

  @override
  bool get hasCompletedOnboarding => signedIn;

  @override
  int? get userId => signedIn ? 17 : null;

  @override
  int get currentStreak => signedIn ? 3 : 0;

  @override
  bool get isPro => false;

  @override
  Future<bool> syncEntitlement() async => true;
}

class _FakePurchaseService implements PurchaseServiceApi {
  const _FakePurchaseService(this.result);

  final PurchaseFlowResult result;

  @override
  Future<PurchaseFlowResult> purchaseMonthly(int userId) async => result;

  @override
  Future<PurchaseFlowResult> restore(int userId) async => result;
}

Future<void> _pumpPaywall(
  WidgetTester tester,
  PurchaseFlowResult result,
) async {
  final auth = _StaticAuthController(signedIn: true);
  final router = GoRouter(
    initialLocation: '/paywall',
    routes: [
      GoRoute(path: '/paywall', builder: (_, __) => const PaywallScreen()),
      GoRoute(
        path: '/profile',
        builder: (_, __) => const Scaffold(body: Text('Profile destination')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authControllerProvider.overrideWith((ref) => auth),
        purchaseServiceProvider.overrideWithValue(_FakePurchaseService(result)),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
}
