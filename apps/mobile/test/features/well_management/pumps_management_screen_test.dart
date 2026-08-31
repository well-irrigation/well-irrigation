import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';
import 'package:well_irrigation_mobile/features/well_management/pumps_management_screen.dart';

/// مستودع مزيَّف يعيد ما يعيده عقد api.list_well_pumps_detail بأسماء
/// ووحدات القاعدة نفسها: القدرة نص حر، والتدفق لتر/دقيقة، والوقود مل/ساعة.
class _FakeWellManagementRepository extends WellManagementRepository {
  String? savedName;
  String? savedStatus;

  @override
  Future<List<PumpModel>> fetchPumps(
    String wellId, {
    bool includeInactive = true,
  }) async {
    return [
      PumpModel(
        id: 'pump-1',
        wellId: wellId,
        publicCode: 'PMP-001',
        name: 'Frankline 75HP',
        pumpType: 'submersible',
        powerRating: '75 HP',
        estimatedWaterFlowLitersPerMinute: 1200,
        estimatedFuelMlPerHour: 9000,
        status: 'active',
      ),
      PumpModel(
        id: 'pump-2',
        wellId: wellId,
        publicCode: 'PMP-002',
        name: 'Caprari 50HP',
        pumpType: 'surface',
        powerRating: '50 HP',
        status: 'maintenance',
      ),
    ];
  }

  @override
  Future<({bool created, String pumpId})> savePump({
    required String wellId,
    required String name,
    String? pumpId,
    String? pumpType,
    String? powerRating,
    double? estimatedWaterFlowLitersPerMinute,
    int? estimatedFuelMlPerHour,
    String status = 'active',
    DateTime? installedAt,
    String? notes,
  }) async {
    savedName = name;
    savedStatus = status;
    return (pumpId: pumpId ?? 'pump-new', created: pumpId == null);
  }
}

void main() {
  group('PumpsManagementScreen Tests (UX-15 / 466–472)', () {
    testWidgets('1. عرض قائمة المضخات وحالاتها ومواصفاتها الفنية', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: PumpsManagementScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            repository: _FakeWellManagementRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('إدارة المضخات والمعدات'), findsOneWidget);
      expect(find.textContaining('المضخات المسجلة'), findsOneWidget);
      expect(find.textContaining('Frankline 75HP'), findsOneWidget);
      expect(find.textContaining('Caprari 50HP'), findsOneWidget);
      expect(find.text('إضافة مضخة جديدة'), findsOneWidget);
      // الحالات الأربع وحدها معتمدة؛ لا running ولا standby.
      expect(find.text('جاهزة للعمل ✅'), findsOneWidget);
      expect(find.textContaining('صيانة'), findsWidgets);
    });

    testWidgets('2. فتح نافذة إضافة مضخة جديدة والتحقق من الحقول والخيارات', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: PumpsManagementScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            repository: _FakeWellManagementRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('إضافة مضخة جديدة'));
      await tester.pumpAndSettle();

      expect(find.text('إضافة مضخة جديدة'), findsWidgets);
      expect(find.text('اسم / نوع المضخة *'), findsOneWidget);
      expect(find.text('نوع المضخة'), findsOneWidget);
      // الوحدات والأسماء صارت أسماء القاعدة نفسها (ق-99).
      expect(find.text('القدرة (نص حر)'), findsOneWidget);
      expect(find.text('التدفق (لتر/دقيقة)'), findsOneWidget);
      expect(
        find.text('معدل استهلاك الديزل التقديري (مل/ساعة)'),
        findsOneWidget,
      );
      expect(find.text('إضافة المضخة'), findsOneWidget);
    });
  });
}
