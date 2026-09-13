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

  // درجات مشتقّة من ألوان العلامة الثلاثة — لتمييز مداخل الأقسام.
  //
  // **لماذا لا ألوان جاهزة:** كانت الشبكة تستعمل `Colors.deepOrange` و
  // `Colors.indigo` و`Colors.teal` — ألوان مكتبة Flutter لا لوحة المشروع،
  // والوثيقة تنصّ: «لا يضاف لون دافئ رابع إلى ألوان العلامة». وكانت تستعمل
  // `warning` (لون تحذير **دلالي**) لمدخل «الشركاء والأرباح»: فلونُ خطرٍ على
  // باب عادي يقول للعين «انتبه، هنا مشكلة» ولا مشكلة — والوثيقة تفصل الألوان
  // الدلالية عن ألوان العلامة، ولا تجعل أخضر العلامة يعني «نجاح».
  //
  // فهذه درجات من الثلاثة وحدها: تُمايز المداخل بلا أن تُدخل هوية غريبة ولا
  // أن تُلبس بابًا معنى حالة.
  static const Color deepBlueLight = Color(0xFF1E4E8C);
  static const Color waterBlueDark = Color(0xFF014C8C);
  static const Color greenDeep = Color(0xFF1E6B1E);
  static const Color greenLight = Color(0xFF43A047);
}
