import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/features/bookings/booking_form_screen.dart';
import 'package:well_irrigation_mobile/features/bookings/bookings_screen.dart';

import '../../support/identity_fixture.dart';

class _FakeOps extends OperationsRepository {
  _FakeOps({this.farmer, this.farm}) : super(null);
  final FarmerAccount? farmer;
  final Farm? farm;

  @override
  Future<List<FarmerAccount>> fetchFarmers(
    String wellId, {
    String? query,
  }) async => farmer == null ? const [] : [farmer!];

  @override
  Future<List<Farm>> fetchFarms(
    String wellId, {
    String? farmerAccountId,
  }) async => farm == null ? const [] : [farm!];
}

class _FakeBookingRepo extends BookingRepository {
  _FakeBookingRepo({this.result, this.future, this.throwError = false})
    : super(null);
  final BookingMutationResult? result;
  final Future<BookingMutationResult>? future;
  final bool throwError;
  int createCalls = 0;

  @override
  Future<BookingMutationResult> createBooking({
    required String wellId,
    required String farmerWellAccountId,
    required String farmId,
    required DateTime scheduledStart,
    required DateTime scheduledEnd,
    required String commandId,
    String? expectedEnergySource,
    String? alternativeEnergySource,
    int priority = 0,
    String? notes,
  }) {
    createCalls++;
    if (throwError) throw StateError('transport');
    if (future != null) return future!;
    return Future.value(
      result ?? const BookingMutationResult(status: 'created', bookingId: 'b1'),
    );
  }
}

const _farmer = FarmerAccount(
  id: 'f1',
  fullName: 'أحمد المزارع',
  publicCode: 'F-1',
);
const _farm = Farm(id: 'farm1', wellId: 'well-1', name: 'الأرض الشمالية');

Future<void> _pickFarmerAndFarm(WidgetTester tester) async {
  await tester.tap(find.text('ابحث بالاسم أو الرمز'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('أحمد المزارع').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('ابحث عن الأرض'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('الأرض الشمالية').last);
  await tester.pumpAndSettle();
}

void main() {
  Widget wrap(Widget child) => MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('ar')],
    home: Directionality(textDirection: TextDirection.rtl, child: child),
  );

  void sizeLarge(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  // تاريخ ثابت ليس اليوم: يجعل وقت البداية الافتراضي 08:00 حتميًّا.
  final fixedDate = DateTime(2027, 1, 15);

  group('دوال حساب الموعد (مصدر حقيقة واحد)', () {
    test('النهاية = البداية + المدة', () {
      final s = DateTime(2026, 10, 10, 8);
      expect(bookingEndFromDuration(s, 150), DateTime(2026, 10, 10, 10, 30));
    });

    test('المدة = الفرق بين البداية والنهاية', () {
      final s = DateTime(2026, 10, 10, 8);
      final e = DateTime(2026, 10, 10, 11, 15);
      expect(bookingDurationMinutes(s, e), 195);
    });

    test('نهاية ≤ بداية تُنتج مدة غير موجبة فتُرفض', () {
      final s = DateTime(2026, 10, 10, 8);
      expect(bookingDurationMinutes(s, s) <= 0, isTrue);
      expect(bookingDurationMinutes(s, DateTime(2026, 10, 10, 7)) <= 0, isTrue);
    });

    test('تنسيق المدة العربي', () {
      expect(formatBookingDuration(150), 'ساعتان و30 دقيقة');
      expect(formatBookingDuration(195), '3 ساعات و15 دقيقة');
      expect(formatBookingDuration(60), 'ساعة');
      expect(formatBookingDuration(45), '45 دقيقة');
    });
  });

  group('نافذة الطاقة الشمسية (مرآة عقد الخادم 06:00–18:00 عدن)', () {
    test('01:00 ترفض الشمسية (بداية خارج النافذة)', () {
      expect(
        assessSolarWindow(startMinuteOfDay: 1 * 60, durationMinutes: 60),
        SolarAssessment.startOutsideWindow,
      );
    });

    test('08:00 تسمح بالشمسية (داخل النافذة)', () {
      expect(
        assessSolarWindow(startMinuteOfDay: 8 * 60, durationMinutes: 60),
        SolarAssessment.ok,
      );
    });

    test('17:00 → 19:00 يتطلب مصدرًا بديلًا', () {
      expect(
        assessSolarWindow(startMinuteOfDay: 17 * 60, durationMinutes: 120),
        SolarAssessment.requiresAlternative,
      );
    });

    test('حدود النافذة: 06:00 مقبولة، 17:59 مقبولة، 18:00 مرفوضة', () {
      expect(
        assessSolarWindow(startMinuteOfDay: 6 * 60, durationMinutes: 60),
        SolarAssessment.ok,
      );
      expect(
        assessSolarWindow(startMinuteOfDay: 17 * 60 + 59, durationMinutes: 1),
        SolarAssessment.ok,
      );
      expect(
        assessSolarWindow(startMinuteOfDay: 18 * 60, durationMinutes: 60),
        SolarAssessment.startOutsideWindow,
      );
    });

    test('مستقلّ عن منطقة الجهاز: القيمة الاسمية وحدها تحكم', () {
      // DateTime مبنيّ بمكوّنات صريحة: hour/minute ثابتان مهما كانت منطقة
      // الجهاز، والتقييم لا يستدعي now ولا toUtc ولا تحويلًا محليًّا.
      for (final selected in [
        DateTime(2026, 10, 11, 1),
        DateTime(2026, 1, 1, 1),
        DateTime(2026, 7, 1, 1),
      ]) {
        expect(solarStartMinuteOfDay(selected), 60);
        expect(
          assessSolarWindow(
            startMinuteOfDay: solarStartMinuteOfDay(selected),
            durationMinutes: 60,
          ),
          SolarAssessment.startOutsideWindow,
        );
      }
    });

    test('ترجمة أسباب الرفض المنظّمة إلى رسائل عربية', () {
      expect(
        bookingRejectionMessage('solar_start_outside_window'),
        'لا يمكن استخدام الطاقة الشمسية في وقت بداية هذا الحجز.',
      );
      expect(
        bookingRejectionMessage('missing_alternative_energy_source'),
        'يمتد الحجز بعد انتهاء وقت الطاقة الشمسية. اختر مصدر الطاقة البديل.',
      );
      expect(bookingRejectionMessage('active_pump_missing'), isNotNull);
      expect(bookingRejectionMessage('unknown_code'), isNull);
    });
  });

  testWidgets('التحقق يطلب المزارع قبل أي محاولة إنشاء', (tester) async {
    sizeLarge(tester);
    final repo = _FakeBookingRepo();
    await tester.pumpWidget(
      wrap(
        BookingFormScreen(
          identity: testIdentity(),
          bookingRepository: repo,
          operationsRepository: _FakeOps(),
          initialDate: fixedDate,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('حفظ الحجز'), findsOneWidget);
    await tester.tap(find.text('حفظ الحجز'));
    await tester.pump();
    expect(find.text('اختر المزارع.'), findsOneWidget);
    expect(repo.createCalls, 0);
  });

  testWidgets('الإنشاء دون اتصال محجوب بلا ادعاء نجاح', (tester) async {
    sizeLarge(tester);
    final repo = _FakeBookingRepo();
    await tester.pumpWidget(
      wrap(
        BookingFormScreen(
          identity: testIdentity(),
          bookingRepository: repo,
          operationsRepository: _FakeOps(farmer: _farmer, farm: _farm),
          initialDate: fixedDate,
          online: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ الحجز'));
    await tester.pump();
    expect(repo.createCalls, 0);
  });

  testWidgets('المدة الافتراضية 08:00 والشريحة «ساعتان» تحسب نهاية 10:00', (
    tester,
  ) async {
    sizeLarge(tester);
    await tester.pumpWidget(
      wrap(
        BookingFormScreen(
          identity: testIdentity(),
          bookingRepository: _FakeBookingRepo(),
          operationsRepository: _FakeOps(),
          initialDate: fixedDate,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // البداية 08:00 والمدة 60 ⇒ النهاية المحسوبة 09:00.
    expect(find.textContaining('09:00'), findsWidgets);
    await tester.tap(find.text('ساعتان'));
    await tester.pumpAndSettle();
    // المدة الآن 120 ⇒ النهاية المحسوبة 10:00.
    expect(find.textContaining('10:00'), findsWidgets);
  });

  testWidgets('التبديل لوضع «بوقت النهاية» يُظهر المدة محسوبة', (tester) async {
    sizeLarge(tester);
    await tester.pumpWidget(
      wrap(
        BookingFormScreen(
          identity: testIdentity(),
          bookingRepository: _FakeBookingRepo(),
          operationsRepository: _FakeOps(),
          initialDate: fixedDate,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('بوقت النهاية'));
    await tester.pumpAndSettle();
    // في وضع النهاية تُعرض «مدة السقي» كقيمة محسوبة.
    expect(find.textContaining('مدة السقي'), findsOneWidget);
  });

  testWidgets('النقر على التاريخ يفتح منتقي التقويم', (tester) async {
    sizeLarge(tester);
    await tester.pumpWidget(
      wrap(
        BookingFormScreen(
          identity: testIdentity(),
          bookingRepository: _FakeBookingRepo(),
          operationsRepository: _FakeOps(),
          initialDate: fixedDate,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('التاريخ'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
  });

  testWidgets('تعارض الوقت يظهر كرسالة أعمال عربية مع بقاء القيم', (
    tester,
  ) async {
    sizeLarge(tester);
    final repo = _FakeBookingRepo(
      result: const BookingMutationResult(
        status: 'conflict',
        message: 'هذا الوقت محجوز بالفعل.',
      ),
    );
    await tester.pumpWidget(
      wrap(
        BookingFormScreen(
          identity: testIdentity(),
          bookingRepository: repo,
          operationsRepository: _FakeOps(farmer: _farmer, farm: _farm),
          initialDate: fixedDate,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('ابحث بالاسم أو الرمز'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('أحمد المزارع').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('ابحث عن الأرض'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الأرض الشمالية').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('ديزل البئر'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('حفظ الحجز'));
    await tester.pumpAndSettle();

    expect(repo.createCalls, 1);
    expect(find.textContaining('هذا الوقت محجوز بالفعل'), findsOneWidget);
    // القيم محفوظة بعد التعارض.
    expect(find.text('أحمد المزارع'), findsWidgets);
  });

  testWidgets('منع الإرسال المزدوج أثناء تنفيذ الحفظ', (tester) async {
    sizeLarge(tester);
    final completer = Completer<BookingMutationResult>();
    final repo = _FakeBookingRepo(future: completer.future);
    await tester.pumpWidget(
      wrap(
        BookingFormScreen(
          identity: testIdentity(),
          bookingRepository: repo,
          operationsRepository: _FakeOps(farmer: _farmer, farm: _farm),
          initialDate: fixedDate,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('ابحث بالاسم أو الرمز'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('أحمد المزارع').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('ابحث عن الأرض'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الأرض الشمالية').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('ديزل البئر'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('حفظ الحجز'));
    await tester.pump();
    // الزر الآن قيد التنفيذ ومعطّل.
    expect(find.text('جارٍ الحفظ...'), findsOneWidget);
    await tester.tap(find.text('جارٍ الحفظ...'), warnIfMissed: false);
    await tester.pump();
    expect(repo.createCalls, 1);

    completer.complete(
      const BookingMutationResult(status: 'conflict', message: 'x'),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('بداية 01:00 + شمسية: حجب محلي بلا نداء شبكة', (tester) async {
    sizeLarge(tester);
    final repo = _FakeBookingRepo();
    await tester.pumpWidget(
      wrap(
        BookingFormScreen(
          identity: testIdentity(),
          bookingRepository: repo,
          operationsRepository: _FakeOps(farmer: _farmer, farm: _farm),
          initialDate: DateTime(2026, 10, 11, 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _pickFarmerAndFarm(tester);
    await tester.tap(find.text('طاقة شمسية'));
    await tester.pumpAndSettle();
    // رسالة فورية بجوار قسم الطاقة + نافذة الشمس المعروضة.
    expect(
      find.text('لا يمكن استخدام الطاقة الشمسية في وقت بداية هذا الحجز.'),
      findsWidgets,
    );
    expect(find.textContaining('نافذة الطاقة الشمسية'), findsOneWidget);
    await tester.tap(find.text('حفظ الحجز'));
    await tester.pumpAndSettle();
    expect(repo.createCalls, 0);
  });

  testWidgets('ديزل البئر عند 01:00: يمضي للخادم (لا حجب شمسي)', (
    tester,
  ) async {
    sizeLarge(tester);
    final completer = Completer<BookingMutationResult>();
    final repo = _FakeBookingRepo(future: completer.future);
    await tester.pumpWidget(
      wrap(
        BookingFormScreen(
          identity: testIdentity(),
          bookingRepository: repo,
          operationsRepository: _FakeOps(farmer: _farmer, farm: _farm),
          initialDate: DateTime(2026, 10, 11, 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _pickFarmerAndFarm(tester);
    await tester.tap(find.text('ديزل البئر'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ الحجز'));
    await tester.pump();
    expect(repo.createCalls, 1);
    completer.complete(const BookingMutationResult(status: 'conflict'));
    await tester.pumpAndSettle();
  });

  testWidgets('شمسية نهارًا داخل النافذة: تمضي للخادم', (tester) async {
    sizeLarge(tester);
    final completer = Completer<BookingMutationResult>();
    final repo = _FakeBookingRepo(future: completer.future);
    await tester.pumpWidget(
      wrap(
        BookingFormScreen(
          identity: testIdentity(),
          bookingRepository: repo,
          operationsRepository: _FakeOps(farmer: _farmer, farm: _farm),
          initialDate: DateTime(2026, 10, 11, 10),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _pickFarmerAndFarm(tester);
    await tester.tap(find.text('طاقة شمسية'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ الحجز'));
    await tester.pump();
    expect(repo.createCalls, 1);
    completer.complete(const BookingMutationResult(status: 'conflict'));
    await tester.pumpAndSettle();
  });

  testWidgets('رفض أعمال منظّم برسالة محددة لا عموم «لم يكتمل»', (
    tester,
  ) async {
    sizeLarge(tester);
    final repo = _FakeBookingRepo(
      result: const BookingMutationResult(
        status: 'rejected',
        reasonCode: 'active_pump_missing',
      ),
    );
    await tester.pumpWidget(
      wrap(
        BookingFormScreen(
          identity: testIdentity(),
          bookingRepository: repo,
          operationsRepository: _FakeOps(farmer: _farmer, farm: _farm),
          initialDate: DateTime(2026, 10, 11, 10),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _pickFarmerAndFarm(tester);
    await tester.tap(find.text('ديزل البئر'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ الحجز'));
    await tester.pumpAndSettle();
    expect(repo.createCalls, 1);
    expect(find.textContaining('لا توجد مضخة فعّالة'), findsWidgets);
    expect(find.textContaining('لم يكتمل'), findsNothing);
  });

  testWidgets('فشل النقل يُظهر رسالة إعادة محاولة عامة', (tester) async {
    sizeLarge(tester);
    final repo = _FakeBookingRepo(throwError: true);
    await tester.pumpWidget(
      wrap(
        BookingFormScreen(
          identity: testIdentity(),
          bookingRepository: repo,
          operationsRepository: _FakeOps(farmer: _farmer, farm: _farm),
          initialDate: DateTime(2026, 10, 11, 10),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _pickFarmerAndFarm(tester);
    await tester.tap(find.text('ديزل البئر'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ الحجز'));
    await tester.pumpAndSettle();
    expect(find.textContaining('تعذّر إتمام الحفظ'), findsOneWidget);
  });
}
