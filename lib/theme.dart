import 'package:flutter/material.dart';

/// 原创视觉方案：深墨底色 + 雾青强调色，圆角卡片，柔和发光。
class AppColors {
  static const bg = Color(0xFF0A0D12);
  static const surface = Color(0xFF141922);
  static const surfaceAlt = Color(0xFF1B2230);
  static const stroke = Color(0xFF2A3344);
  static const accent = Color(0xFF3DE0C0);
  static const accentDim = Color(0xFF1D7F6E);
  static const textPrimary = Color(0xFFEAF1F7);
  static const textSecondary = Color(0xFF8A99AC);
  static const danger = Color(0xFFFF6B6B);
}

class AppTheme {
  static ThemeData build() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.bg,
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.accent,
        secondary: AppColors.accent,
        surface: AppColors.surface,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textPrimary,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppColors.surfaceAlt,
        contentTextStyle: TextStyle(color: AppColors.textPrimary),
        behavior: SnackBarBehavior.floating,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.bg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.stroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.stroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.6),
        ),
        hintStyle: const TextStyle(color: AppColors.textSecondary),
      ),
    );
  }
}
