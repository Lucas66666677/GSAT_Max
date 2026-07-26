import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../config/app_config.dart';

enum PurchaseFlowStatus { purchased, restored, cancelled, unavailable, failed }

class PurchaseFlowResult {
  const PurchaseFlowResult(this.status, this.message);

  final PurchaseFlowStatus status;
  final String message;
}

abstract interface class PurchaseServiceApi {
  Future<PurchaseFlowResult> purchaseMonthly(int userId);

  Future<PurchaseFlowResult> restore(int userId);
}

class PurchaseService implements PurchaseServiceApi {
  PurchaseService._();

  static final PurchaseService instance = PurchaseService._();

  bool _configured = false;
  String? _configuredUserId;

  Future<void> initialize(int userId) async {
    if (!AppConfig.hasRevenueCatKey) {
      throw StateError('RevenueCat API key is not configured for this build.');
    }
    final appUserId = userId.toString();
    if (_configured && _configuredUserId == appUserId) return;
    if (_configured) {
      await Purchases.logIn(appUserId);
      _configuredUserId = appUserId;
      return;
    }
    await Purchases.setLogLevel(
      AppConfig.isProduction ? LogLevel.warn : LogLevel.debug,
    );
    final configuration = PurchasesConfiguration(AppConfig.revenueCatApiKey)
      ..appUserID = appUserId;
    await Purchases.configure(configuration);
    _configured = true;
    _configuredUserId = appUserId;
  }

  @override
  Future<PurchaseFlowResult> purchaseMonthly(int userId) async {
    try {
      await initialize(userId);
      final offerings = await Purchases.getOfferings();
      final current = offerings.current;
      if (current == null || current.availablePackages.isEmpty) {
        return const PurchaseFlowResult(
          PurchaseFlowStatus.unavailable,
          'No subscription package is available for this store account.',
        );
      }
      final package = current.monthly ?? current.availablePackages.first;
      await Purchases.purchasePackage(package);
      return const PurchaseFlowResult(
        PurchaseFlowStatus.purchased,
        'Purchase completed. Waiting for secure server entitlement sync.',
      );
    } on PlatformException catch (error) {
      final code = PurchasesErrorHelper.getErrorCode(error);
      if (code == PurchasesErrorCode.purchaseCancelledError) {
        return const PurchaseFlowResult(
          PurchaseFlowStatus.cancelled,
          'Purchase cancelled. No charge was made.',
        );
      }
      return PurchaseFlowResult(
        PurchaseFlowStatus.failed,
        error.message ?? 'The store could not complete this purchase.',
      );
    } catch (error) {
      return PurchaseFlowResult(PurchaseFlowStatus.failed, error.toString());
    }
  }

  @override
  Future<PurchaseFlowResult> restore(int userId) async {
    try {
      await initialize(userId);
      await Purchases.restorePurchases();
      return const PurchaseFlowResult(
        PurchaseFlowStatus.restored,
        'Restore completed. Waiting for secure server entitlement sync.',
      );
    } on PlatformException catch (error) {
      return PurchaseFlowResult(
        PurchaseFlowStatus.failed,
        error.message ?? 'Purchases could not be restored.',
      );
    } catch (error) {
      return PurchaseFlowResult(PurchaseFlowStatus.failed, error.toString());
    }
  }
}
