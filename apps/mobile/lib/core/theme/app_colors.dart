import 'package:flutter/material.dart';

/// ثوابت الألوان المعتمدة للهوية البصرية (VISUAL_IDENTITY.md - القسم 4 و 5)
class AppColors {
  AppColors._();

  // ألوان العلامة الأساسية
  static const Color deepBlue = Color(0xFF022E62);
  static const Color waterBlue = Color(0xFF0265BA);
  static const Color agriculturalGreen = Color(0xFF2A8B2A);

  // الخلفيات والأسطح
  static const Color splashBackground = Color(0xFFF8FAFC); // خلفية بيضاء باردة خفيفة
  static const Color background = Color(0xFFFFFFFF);
  static const Color surface = Color(0xFFF1F5F9);
  static const Color surfaceSubtle = Color(0xFFE2E8F0);

  // النصوص
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF475569);
  static const Color textMuted = Color(0xFF94A3B8);

  // الألوان الدلالية (Semantic Colors)
  static const Color success = Color(0xFF16A34A);
  static const Color warning = Color(0xFFD97706);
  static const Color error = Color(0xFFDC2626);
  static const Color info = Color(0xFF2563EB);

  // الحدود
  static const Color border = Color(0xFFCBD5E1);
  static const Color borderFocused = Color(0xFF0265BA);
}
