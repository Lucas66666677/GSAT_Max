import 'package:flutter/material.dart';

/// Generated from the Lucirel Wave Gate v1.0 design language.
/// Product code should consume these semantic tokens instead of inventing
/// local colors or component geometry.
abstract final class LucirelColors {
  static const background = Color(0xFF101827);
  static const surface = Color(0xF017233C);
  static const surfaceStrong = Color(0xFF1D2942);
  static const border = Color(0x405A6B86);
  static const textPrimary = Color(0xFFF8FAFC);
  static const textSecondary = Color(0xFFC7D2E4);
  static const textTertiary = Color(0xFF94A3B8);
  static const primary = Color(0xFF60A5FA);
  static const secondary = Color(0xFF2DD4BF);
  static const danger = Color(0xFFF87171);
  static const focusBackground = Color(0xFF0A0A0A);
  static const focusSurface = Color(0xFF181818);
}

ThemeData buildLucirelTheme({required bool focusMode}) {
  final primaryColor = focusMode ? Colors.white : LucirelColors.primary;
  final secondaryColor =
      focusMode ? const Color(0xFFD4D4D4) : LucirelColors.secondary;
  final scaffoldColor =
      focusMode ? LucirelColors.focusBackground : LucirelColors.background;
  final surfaceColor =
      focusMode ? LucirelColors.focusSurface : LucirelColors.surfaceStrong;

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'NotoSansTC',
    colorScheme: ColorScheme.fromSeed(
      seedColor: primaryColor,
      brightness: Brightness.dark,
    ).copyWith(
      primary: primaryColor,
      secondary: secondaryColor,
      surface: surfaceColor,
    ),
    scaffoldBackgroundColor: scaffoldColor,
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        color: LucirelColors.textPrimary,
        fontWeight: FontWeight.w900,
      ),
      headlineSmall: TextStyle(
        color: LucirelColors.textPrimary,
        fontWeight: FontWeight.w900,
      ),
      titleLarge: TextStyle(
        color: LucirelColors.textPrimary,
        fontWeight: FontWeight.w900,
      ),
      titleMedium: TextStyle(
        color: LucirelColors.textPrimary,
        fontWeight: FontWeight.w800,
      ),
      bodyLarge: TextStyle(color: LucirelColors.textSecondary),
      bodyMedium: TextStyle(color: LucirelColors.textSecondary),
      bodySmall: TextStyle(color: LucirelColors.textTertiary),
      labelLarge: TextStyle(
        color: LucirelColors.textSecondary,
        fontWeight: FontWeight.w700,
      ),
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      elevation: 0,
      backgroundColor: Colors.transparent,
      foregroundColor: LucirelColors.textPrimary,
      surfaceTintColor: Colors.transparent,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: focusMode ? Colors.black : const Color(0xF0101827),
      selectedItemColor: primaryColor,
      unselectedItemColor: LucirelColors.textTertiary,
      type: BottomNavigationBarType.fixed,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: primaryColor,
        foregroundColor: focusMode ? Colors.black : const Color(0xFF071321),
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
          color: focusMode ? Colors.white70 : LucirelColors.border,
        ),
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
      foregroundColor: focusMode ? Colors.black : const Color(0xFF071321),
    ),
    chipTheme: ChipThemeData(
      backgroundColor:
          focusMode ? const Color(0xFF202020) : const Color(0x991D2942),
      selectedColor: primaryColor.withOpacity(0.18),
      disabledColor: const Color(0x331D2942),
      side: BorderSide(
        color: focusMode ? Colors.white24 : LucirelColors.border,
      ),
      labelStyle: const TextStyle(
        color: LucirelColors.textSecondary,
        fontWeight: FontWeight.w700,
      ),
      secondaryLabelStyle: const TextStyle(color: LucirelColors.textPrimary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: const Color(0xF01D2942),
      contentTextStyle: const TextStyle(
        color: LucirelColors.textPrimary,
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
          focusMode ? LucirelColors.focusSurface : const Color(0xD01D2942),
      labelStyle: const TextStyle(color: LucirelColors.textSecondary),
      hintStyle: const TextStyle(color: LucirelColors.textTertiary),
      prefixIconColor: LucirelColors.textTertiary,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color: focusMode ? Colors.white24 : LucirelColors.border,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color: focusMode ? Colors.white24 : LucirelColors.border,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: primaryColor, width: 2),
      ),
    ),
  );
}

class LucirelProductBrand extends StatelessWidget {
  const LucirelProductBrand({
    super.key,
    this.compact = false,
    this.markSize = 42,
  });

  final bool compact;
  final double markSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(markSize * 0.24),
          child: Image.asset(
            'assets/brand/lucirel-wave-gate.png',
            width: markSize,
            height: markSize,
            semanticLabel: 'Lucirel Wave Gate',
          ),
        ),
        const SizedBox(width: 11),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'GSAT Max',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: LucirelColors.textPrimary,
                      fontWeight: FontWeight.w900,
                    ),
              ),
              if (!compact)
                const Text(
                  '學測英文訓練 · by Lucirel',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: LucirelColors.textTertiary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
