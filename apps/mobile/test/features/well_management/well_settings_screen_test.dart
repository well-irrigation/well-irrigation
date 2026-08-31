import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';
import 'package:well_irrigation_mobile/features/well_management/well_settings_screen.dart';

/// مستودع مزيَّف يعيد ما يعيده عقد api.get_well_details، ويسجّل ما أُرسل
/// إلى api.update_well_details للتحقق من دلالة «مرسَل = يُحدَّث».
class _FakeWellManagementRepository extends WellManagementRepository {
  double? sentDepthMeters;
  String? sentName;
  String? sentLocation;

  @override
  Future<WellDetailsModel> fetchWellDetails(String wellId) async {
    return WellDetailsModel(
      id: wellId,
      tenantId: 'tenant-1',
      name: 'بئر الخير الرئيسي',
      status: 'active',
      location: 'وادي حضرموت - الغرفة',
      depthMeters: 180,
      staticWaterLevelMeters: 45.5,
      notes: 'تشغيل بالطاقة الشمسية صباحًا',
    );
  }

  @override
  Future<String> updateWellDetails({
    required String wellId,
    required String name,
    String? location,
    double? depthMeters,
    double? staticWaterLevelMeters,
    String? notes,
  }) async {
    sentName = name;
    sentLocation = location;
    sentDepthMeters = depthMeters;
    return wellId;
  }
}

void main() {
  group('WellSettingsScreen Tests (UX-15 / 460–465)', () {
    testWidgets('1. عرض بيانات البئر ومحدد البئر والحالة التشغيلية', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: WellSettingsScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            repository: _FakeWellManagementRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('بيانات وإعدادات البئر'), findsOneWidget);
      expect(find.text('حالة البئر: نشط وتشغيلي'), findsOneWidget);
      expect(find.text('اسم البئر المعتمد *'), findsOneWidget);
      expect(find.text('الموقع الجغرافي / الحوض / المنطقة'), findsOneWidget);
      expect(find.text('العمق الكلي (متر)'), findsOneWidget);
      expect(find.text('منسوب المياه الساكن (متر)'), findsOneWidget);
      expect(find.text('حفظ التغييرات صراحة'), findsOneWidget);
      expect(find.textContaining('ضوابط السلامة'), findsOneWidget);
      // العمق ومنسوب الماء عشريان: القيمة المخزَّنة 45.5 تُعرض بمنزلتها
      // (العمق 180 يطابق نص التلميح نفسه، فلا يصلح للتمييز).
      expect(find.text('45.5'), findsOneWidget);
    });

    testWidgets('2. تعديل الاسم والعمق والضغط على حفظ التغييرات صراحة', (tester) async {
      final repository = _FakeWellManagementRepository();

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: WellSettingsScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            repository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final depthFinder = find.widgetWithText(TextFormField, 'العمق الكلي (متر)');
      await tester.enterText(depthFinder, '210');
      await tester.pumpAndSettle();

      await tester.tap(find.text('حفظ التغييرات صراحة'));
      await tester.pumpAndSettle();

      expect(find.text('تم حفظ بيانات البئر بنجاح ✅'), findsOneWidget);
      expect(repository.sentDepthMeters, 210);
      expect(repository.sentName, 'بئر الخير الرئيسي');
      expect(repository.sentLocation, 'وادي حضرموت - الغرفة');
    });
  });
}
