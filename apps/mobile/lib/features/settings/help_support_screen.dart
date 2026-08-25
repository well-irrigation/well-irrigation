import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

/// شاشة المساعدة والدعم وعن التطبيق وسياق التشخيص (UX-16A / القرارات 574–577 / ق-101)
class HelpSupportScreen extends StatelessWidget {
  const HelpSupportScreen({super.key});

  void _showSafeDiagnosticContext(BuildContext context) {
    HapticFeedback.lightImpact();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.bug_report_outlined, color: AppColors.waterBlue),
            SizedBox(width: 8),
            Text('سياق التشخيص الآمن', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'وفقاً للقرار 575، يشارك هذا التقرير معلومات النظام الفنية دون كشف أي كلمات مرور أو بيانات سرية:',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            SizedBox(height: 12),
            SelectableText(
              '• إصدار التطبيق: 1.0.0 (Build 101)\n'
              '• المنصة: Android Flutter Engine\n'
              '• بيئة التشغيل: Production Cloud Supabase\n'
              '• المحرك المالي: Whole YER Minor Units\n'
              '• بروتوكول الطباعة: ESC/POS 58mm/80mm\n'
              '• حالة التخزين المحلي: Durable Outbox v1.0',
              style: TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('إغلاق'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.waterBlue,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('نسخ التقرير'),
            onPressed: () {
              Clipboard.setData(
                const ClipboardData(
                  text: 'Well Irrigation App Diagnostic Context\nVersion: 1.0.0 (Build 101)\nPlatform: Android\nStatus: Healthy',
                ),
              );
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('تم نسخ بيانات التشخيص إلى الحافظة بنجاح 📋')),
              );
            },
          ),
        ],
      ),
    );
  }

  void _showPrivacyTerms(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('الشروط وسياسة الخصوصية', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('حماية البيانات والخصوصية:', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Text(
                'يلتزم نظام إدارة وتشغيل آبار الري بحماية البيانات المحاسبية وسجلات الجلسات الميدانية. جميع البيانات مشفرة محلياً وعلى السحابة وفق أعلى معايير الأمان وقواعد RLS الصارمة.',
                style: TextStyle(fontSize: 12, height: 1.4),
              ),
              SizedBox(height: 12),
              Text('المسؤولية التشغيلية:', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Text(
                'البيانات المالية وسندات القبض وحصص الشركاء تخضع لتدقيق معتمد ولا يمكن تعديل السجلات التاريخية صامتاً.',
                style: TextStyle(fontSize: 12, height: 1.4),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.waterBlue, foregroundColor: Colors.white),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('موافق'),
          ),
        ],
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
        title: const Text('المساعدة وعن التطبيق', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 1. بطاقة معلومات التطبيق (القرار 577)
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: AppColors.border),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 36,
                    backgroundColor: AppColors.waterBlue.withValues(alpha: 0.15),
                    child: const Icon(Icons.water_drop, size: 40, color: AppColors.waterBlue),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'نظام إدارة وتشغيل آبار الري',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'الإصدار 1.0.0 (Build 101) — النسخة الميدانية المعتمدة',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.agriculturalGreen.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'نظام معتمد وفق ضوابط الري والمحاسبة الدقيقة ✅',
                      style: TextStyle(color: AppColors.agriculturalGreen, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 2. قنوات الدعم الفني (القرار 574)
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
                  const Text('قنوات الدعم الفني والمساعدة', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                      backgroundColor: Color(0xFF25D366),
                      foregroundColor: Colors.white,
                      child: Icon(Icons.chat),
                    ),
                    title: const Text('المحادثة المباشرة عبر واتساب', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    subtitle: const Text('+967 777 000 000 (دعم فوري على مدار الساعة)', style: TextStyle(fontSize: 12)),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('فتح محادثة واتساب مع الدعم الفني...')),
                      );
                    },
                  ),
                  const Divider(height: 16),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                      backgroundColor: AppColors.waterBlue,
                      foregroundColor: Colors.white,
                      child: Icon(Icons.phone),
                    ),
                    title: const Text('الاتصال الهاتفي المباشر', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    subtitle: const Text('خدمة العملاء ومساندة المشغلين', style: TextStyle(fontSize: 12)),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('الاتصال بفريق الدعم الفني...')),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 3. أدوات التشخيص والمعلومات القانونية (القرارات 575–576)
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: AppColors.border),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.bug_report_outlined, color: AppColors.waterBlue),
                  title: const Text('سياق التشخيص الفني والتقني', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  subtitle: const Text('تقرير آمن لحل المشكلات والأخطاء البرمجية', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                  onTap: () => _showSafeDiagnosticContext(context),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.policy_outlined, color: AppColors.agriculturalGreen),
                  title: const Text('الشروط وسياسة الخصوصية', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  subtitle: const Text('المستندات القانونية وحماية البيانات', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                  onTap: () => _showPrivacyTerms(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
