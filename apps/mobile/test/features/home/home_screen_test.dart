import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/home/home_screen.dart';

import '../../support/identity_fixture.dart';

/// حرس تخطيط الشاشة الرئيسية.
///
/// **لماذا وُجد:** في 2026-09-04 خرجت الشاشة **بيضاء بالكامل** على الجهاز بعد
/// إعادة بناء شبكة الأقسام: صفٌّ بـ`CrossAxisAlignment.stretch` داخل قائمة
/// تمرير عمودية يطلب ارتفاعًا لا نهائيًّا، فتسقط عملية التخطيط. ولا اختبار
/// واحد كان يبني هذه الشاشة — فالحزمة كانت 355 نجاحًا والشاشة الأولى لا
/// تُرسم. **اختبارٌ لا يبني الشاشة لا يعرف أنها تُرسم** (ق-113).
void main() {
  Widget wrap() {
    return MaterialApp(
      locale: const Locale('ar'),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: HomeScreen(identity: testIdentity()),
      ),
    );
  }

  testWidgets('الرئيسية تُرسم بلا استثناء تخطيط وتعرض مداخلها التسعة', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // أي استثناء تخطيط يُرصد هنا، فيفشل الاختبار بسببه لا بغيابه.
    expect(tester.takeException(), isNull);

    // المداخل التسعة بأسمائها المعتمدة (القرارات 220–229).
    for (final title in const [
      'التشغيل والسقي',
      'سجل الجلسات',
      'المزارعون والأراضي',
      'الحسابات',
      'المصروفات',
      'الشركاء والأرباح',
      'البئر والمعدات',
      'التقارير',
      'المزيد',
    ]) {
      expect(find.text(title), findsOneWidget, reason: 'المدخل مفقود: $title');
    }
  });

  testWidgets('لا وصف تحت أي مدخل — القرار 220', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // الأوصاف التي كانت تحت البطاقات: عودتها تُطيل البطاقة وتُخرج مدخلين من
    // الشاشة الأولى.
    for (final subtitle in const [
      'بدء وإيقاف العداد المباشر',
      'تاريخ السقي والتفاصيل',
      'دليل المزارعين والأراضي',
      'تسجيل واعتماد المصروفات',
      'النسب ودورات التوزيع',
    ]) {
      expect(find.text(subtitle), findsNothing, reason: 'وصف عاد: $subtitle');
    }
  });

  testWidgets('البئر غير النشط لا يُعلن جاهزًا للتشغيل', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: HomeScreen(
            identity: testIdentity(wells: [testWell(status: 'inactive')]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('غير نشط'), findsOneWidget);
    expect(find.text('غير متاح للتشغيل'), findsOneWidget);
    expect(find.text('جاهز للتشغيل'), findsNothing);
  });

  testWidgets('لا يفيض رأس الرئيسية عند تكبير النص', (tester) async {
    tester.view.physicalSize = const Size(720, 3200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 1600),
          textScaler: TextScaler.linear(2),
        ),
        child: wrap(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('لا تمرير في الرئيسية — كل المداخل معروضة معًا', (tester) async {
    // شرط معلَن من المالك: الرئيسية بلا تمرير. والتمرير في شاشة المداخل يُخفي
    // أبوابًا لا يعرف المستخدم أنها موجودة، ومَن يعمل بيد واحدة لا يمرّر ليجد
    // بابًا. وحضورُ عنصر تمرير هو الدليل على أن المحتوى تجاوز الشاشة.
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(Scrollable), findsNothing);
  });
}
