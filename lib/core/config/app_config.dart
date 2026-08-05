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

  static const bool disablePermissionPrompts = bool.fromEnvironment(
    'GSAT_MAX_DISABLE_PERMISSION_PROMPTS',
    defaultValue: false,
  );

  static bool get isProduction => environment == 'production';
  static bool get hasRevenueCatKey => revenueCatApiKey.trim().isNotEmpty;

  static Uri apiUri(String path) {
    return resolveApiUri(
      baseUrl: apiBaseUrl,
      path: path,
      web: kIsWeb,
      pageUri: Uri.base,
      production: isProduction,
    );
  }

  static Uri resolveApiUri({
    required String baseUrl,
    required String path,
    required bool web,
    required Uri pageUri,
    required bool production,
  }) {
    final trimmedBase = baseUrl.trim();
    if (trimmedBase.isEmpty) {
      throw StateError('API_BASE_URL cannot be empty.');
    }
    final base = trimmedBase.endsWith('/')
        ? trimmedBase.substring(0, trimmedBase.length - 1)
        : trimmedBase;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final isSameOriginWebPath = web && base.startsWith('/');
    final uri = isSameOriginWebPath
        ? pageUri.resolve('$base$normalizedPath')
        : Uri.parse('$base$normalizedPath');
    if (!uri.hasScheme || uri.host.isEmpty) {
      throw StateError('API_BASE_URL must be absolute outside Flutter Web.');
    }
    final isLocalHost = uri.host == 'localhost' || uri.host == '127.0.0.1';
    if (production && uri.scheme != 'https' && !isLocalHost) {
      throw StateError('Production API_BASE_URL must use HTTPS.');
    }
    return uri;
  }
}
