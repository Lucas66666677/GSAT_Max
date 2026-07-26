import 'package:flutter/foundation.dart';

class AppConfig {
  const AppConfig._();

  static const String environment = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'development',
  );

  // Android emulator is the first Closed Beta target. iOS/desktop developers
  // can pass localhost; physical devices pass the host computer's LAN address.
  static const String _configuredApiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );

  static String get apiBaseUrl {
    if (_configuredApiBaseUrl.trim().isNotEmpty) return _configuredApiBaseUrl;
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? 'http://10.0.2.2:8000'
        : 'http://localhost:8000';
  }

  static const String revenueCatApiKey = String.fromEnvironment(
    'REVENUECAT_API_KEY',
    defaultValue: '',
  );

  static bool get isProduction => environment == 'production';
  static bool get hasRevenueCatKey => revenueCatApiKey.trim().isNotEmpty;

  static Uri apiUri(String path) {
    final base = apiBaseUrl.endsWith('/')
        ? apiBaseUrl.substring(0, apiBaseUrl.length - 1)
        : apiBaseUrl;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$base$normalizedPath');
    if (isProduction && uri.scheme != 'https') {
      throw StateError('Production API_BASE_URL must use HTTPS.');
    }
    return uri;
  }
}
