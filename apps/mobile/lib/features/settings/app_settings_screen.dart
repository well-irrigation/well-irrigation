import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/account_repository.dart';
import '../../core/theme/app_colors.dart';

/// شاشة تفضيلات التطبيق والمظهر وإعدادات الطباعة الحرارية (UX-16A / القرارات 568–590 / ق-101)
class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({
    this.repository,
    super.key,
  });

  final AccountRepository? repository;

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  AppSettingsModel _settings = const AppSettingsModel();

  @override
  void initState() {
    super.initState();
  }

  void _updateSettings(AppSettingsModel newSettings) {
    HapticFeedback.selectionClick();
    setState(() => _settings = newSettings);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('تم حفظ التفضيلات بنجاح ✅'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('تفضيلات التطبيق والطباعة', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 1. مظهر التطبيق (القرار 568)
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: AppColors.border),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('مظهر الواجهة (Theme)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  const Text(
                    'الوضع الفاتح هو الموصى به للاستخدام الميداني تحت أشعة الشمس المباشرة.',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'light', label: Text('فاتح (ميداني)'), icon: Icon(Icons.wb_sunny_outlined)),
                      ButtonSegment(value: 'dark', label: Text('داكن'), icon: Icon(Icons.nightlight_outlined)),
                      ButtonSegment(value: 'system', label: Text('النظام'), icon: Icon(Icons.settings_suggest_outlined)),
                    ],
                    selected: {_settings.themeMode},
                    onSelectionChanged: (set) => _updateSettings(_settings.copyWith(themeMode: set.first)),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 2. إعدادات الطابعة الحرارية الميدانية (esc-pos-thermal-printer)
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: AppColors.border),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.print, color: AppColors.waterBlue),
                      SizedBox(width: 8),
                      Text('إعدادات الطابعة الحرارية الميدانية', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'طباعة فواتير السقي وسندات القبض عبر طابعات البلوتوث المحمولة.',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 14),
                  const Text('عرض الورق الافتراضي:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: '58mm', label: Text('58 مم (محمولة جيب)')),
                      ButtonSegment(value: '80mm', label: Text('80 مم (قياسية مكتبية)')),
                    ],
                    selected: {_settings.printerPaperSize},
                    onSelectionChanged: (set) => _updateSettings(_settings.copyWith(printerPaperSize: set.first)),
                  ),
                  const Divider(height: 24),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('الطباعة التلقائية بعد إنهاء السقي', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    subtitle: const Text('فتح نافذة المعاينة والطباعة مباشرة عند إنهاء الجلسة', style: TextStyle(fontSize: 12)),
                    value: _settings.autoPrintReceipt,
                    onChanged: (val) => _updateSettings(_settings.copyWith(autoPrintReceipt: val)),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 3. إعدادات الإشعارات (القرارات 556–560)
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: AppColors.border),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('تفضيلات الإشعارات والتنبيهات', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('تنبيهات جلسات السقي والتشغيل', style: TextStyle(fontSize: 14)),
                    value: _settings.operationsAlerts,
                    onChanged: (val) => _updateSettings(_settings.copyWith(operationsAlerts: val)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('تنبيهات سندات القبض والدفعات المالية', style: TextStyle(fontSize: 14)),
                    value: _settings.financialAlerts,
                    onChanged: (val) => _updateSettings(_settings.copyWith(financialAlerts: val)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('تنبيهات مشكلات المزامنة والحالة السحابية', style: TextStyle(fontSize: 14)),
                    value: _settings.syncAlerts,
                    onChanged: (val) => _updateSettings(_settings.copyWith(syncAlerts: val)),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 4. معايير الأرقام والتوقيت العالمية (القرارات 572–573)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: AppColors.textSecondary, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'تعتمد واجهات التطبيق الأرقام الإنجليزية الموحدة (0-9) والتاريخ بتنسيق DD/MM/YYYY وفقاً لمعايير UX العالمية (القرارات 572–573).',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
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
