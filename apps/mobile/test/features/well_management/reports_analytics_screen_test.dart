import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';
import 'package:well_irrigation_mobile/features/well_management/reports_analytics_screen.dart';

/// مستودع مزيَّف يعيد غلاف api.get_reports_summary كما هو: الوقود بالمللتر
/// والمدد بالثواني والأسبوع يبدأ السبت، والتحويل إلى لترات وساعات ونِسَب
/// يجري في المحلّل نفسه كما في التطبيق.
class _FakeWellManagementRepository extends WellManagementRepository {
  final List<String> requestedPeriods = <String>[];

  @override
  Future<ReportSummaryModel> fetchReportsSummary({
    required String wellId,
    required String periodCode,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    requestedPeriods.add(periodCode);
    return ReportSummaryModel.fromContract({
      'contract': 'get_reports_summary',
      'version': 1,
      'well_id': wellId,
      'period_code': periodCode,
      'period_start': '2026-08-01T00:00:00Z',
      'period_end': '2026-09-01T00:00:00Z',
      'week_starts_on': 'saturday',
      'totals': {
        'total_sessions': 12,
        'total_duration_seconds': 86400,
        'total_revenue_minor': 640000,
        'total_collected_minor': 480000,
        'total_expenses_minor': 165000,
        'total_fuel_consumed_ml': 320000,
      },
      'daily_irrigation': [
        {
          'day': '2026-08-29',
          'sessions_count': 3,
          'duration_seconds': 21600,
        },
        {
          'day': '2026-08-30',
          'sessions_count': 4,
          'duration_seconds': 28800,
        },
        {
          'day': '2026-08-31',
          'sessions_count': 5,
          'duration_seconds': 36000,
        },
      ],
      'financial_trends': [
        {
          'week_start': '2026-08-22',
          'week_end': '2026-08-28',
          'collected_minor': 180000,
          'expenses_minor': 65000,
        },
        {
          'week_start': '2026-08-29',
          'week_end': '2026-09-04',
          'collected_minor': 300000,
          'expenses_minor': 100000,
        },
      ],
      'energy_distribution': [
        {'energy_source': 'farmer_diesel', 'total_seconds': 10800},
        {'energy_source': 'solar', 'total_seconds': 50400},
        {'energy_source': 'well_diesel', 'total_seconds': 25200},
      ],
    });
  }
}

void main() {
  group('ReportsAnalyticsScreen Tests (UX-15 / 498–521)', () {
    testWidgets('1. عرض مؤشرات الأداء والرسوم البيانية البسيطة V1', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: ReportsAnalyticsScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            repository: _FakeWellManagementRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('التقارير والمؤشرات العامة'), findsOneWidget);
      expect(find.text('اليوم'), findsWidgets);
      expect(find.text('هذا الأسبوع'), findsOneWidget);
      expect(find.text('هذا الشهر'), findsOneWidget);
      expect(find.text('جلسات السقي'), findsOneWidget);
      expect(find.text('استهلاك الديزل'), findsOneWidget);
      expect(find.text('المقبوضات المحصلة'), findsOneWidget);
      expect(find.text('المصروفات المعتمدة'), findsOneWidget);
      expect(find.textContaining('ساعات السقي اليومية'), findsOneWidget);
      expect(find.textContaining('توزيع ساعات السقي حسب مصدر الطاقة'), findsOneWidget);
      expect(find.textContaining('التحصيل مقابل المصروفات'), findsOneWidget);
    });

    testWidgets('2. التبديل بين الفترات الزمنية وتحديث المؤشرات', (tester) async {
      final repo = _FakeWellManagementRepository();

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: ReportsAnalyticsScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            repository: repo,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // التبديل إلى "اليوم"
      await tester.tap(find.text('اليوم').first);
      await tester.pumpAndSettle();

      expect(find.text('جلسات السقي'), findsOneWidget);

      // التبديل إلى "هذا الأسبوع"
      await tester.tap(find.text('هذا الأسبوع'));
      await tester.pumpAndSettle();

      expect(find.text('جلسات السقي'), findsOneWidget);

      // رمز الفترة يُمرَّر إلى العقد ولا يُترجم في الشاشة
      expect(repo.requestedPeriods, ['this_month', 'today', 'this_week']);
    });

    testWidgets('3. الوحدات المعروضة مشتقة من وحدات القاعدة: مللتر وثوانٍ', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: ReportsAnalyticsScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            repository: _FakeWellManagementRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 320000 مل ← 320 لترًا، و86400 ثانية ← 24 ساعة تشغيل.
      expect(find.text('320 لتر'), findsOneWidget);
      expect(find.text('12 جلسة'), findsOneWidget);
      expect(find.text('24 ساعة تشغيل'), findsOneWidget);
      // النِسَب محسوبة من الثواني المُرجَعة: 50400 من 86400 = 58%.
      expect(find.textContaining('طاقة شمسية'), findsOneWidget);
      expect(find.textContaining('58%'), findsOneWidget);
    });
  });
}
