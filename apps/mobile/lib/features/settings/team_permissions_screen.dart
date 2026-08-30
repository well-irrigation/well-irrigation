import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// حالة إدارة الفريق ضمن بوابة التثبيت.
/// لا تعرض بيانات بديلة ولا تنفذ عمليات غير مدعومة من Backend.
class TeamPermissionsScreen extends StatelessWidget {
  const TeamPermissionsScreen({
    required this.wellId,
    required this.wellName,
    super.key,
  });

  final String wellId;
  final String wellName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'الفريق والصلاحيات',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 17,
              ),
            ),
            Text(
              wellName,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(
                color: AppColors.border,
              ),
            ),
            child: const Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(
                    Icons.admin_panel_settings_outlined,
                    size: 44,
                    color: AppColors.warning,
                  ),
                  SizedBox(height: 14),
                  Text(
                    'إدارة الفريق غير متاحة في هذه النسخة',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 10),
                  Text(
                    'لم نعرض أعضاء بديلين، ولم ننفذ إضافة أو تعطيلًا '
                    'غير موثق. يلزم إكمال عقد الخادم الآمن لإدارة '
                    'الفريق قبل تفعيل هذه العمليات.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  SizedBox(height: 14),
                  Text(
                    'لم يتم تغيير أي بيانات فريق من هذه الشاشة.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.waterBlue,
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
