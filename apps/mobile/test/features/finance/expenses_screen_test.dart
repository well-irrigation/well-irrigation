import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/finance_repository.dart';
import 'package:well_irrigation_mobile/core/widgets/currency_text_form_field.dart';
import 'package:well_irrigation_mobile/features/finance/expenses_screen.dart';

import '../../support/identity_fixture.dart';

/// مستودع مزيَّف يعيد ما تعيده عقود الهجرات بأسماء مفاتيح القاعدة نفسها
/// ويمر عبر المحلّلات الحقيقية، ويسجّل النداءات ليثبت الترتيب
/// (الرفع قبل الحفظ) وفصل السبب عن الملاحظة.
class _FakeExpensesRepository extends FinanceRepository {
  _FakeExpensesRepository({
    this.failCategories = false,
    this.emptyCategories = false,
    this.failUpload = false,
    this.failSave = false,
  });

  final bool failCategories;
  final bool emptyCategories;
  final bool failUpload;
  final bool failSave;

  int uploadCalls = 0;
  int saveCalls = 0;
  int resolveCalls = 0;
  final List<String> callOrder = <String>[];
  String? lastCategoryCode;
  String? lastSkipReason;
  String? lastNote;
  bool? lastSkipped;
  String? lastAttachmentUrl;

  @override
  Future<List<ExpenseItem>> fetchExpenses(
    String wellId, {
    String? status,
    int limit = 100,
  }) async {
    final today = DateTime.now();
    final rows = <Map<String, dynamic>>[
      {
        // مصروف معلّق بمرفق — لقرار المالك مع عرض الإثبات.
        'id': 'expense-p1',
        'well_id': wellId,
        'category_code': 'diesel',
        'category_name': 'ديزل',
        'amount_minor': 60000,
        'description': 'تعبئة برميل ديزل',
        'status': 'pending_approval',
        'spent_at': today.toIso8601String(),
        'payment_source': 'cashbox',
        'attachment_url': 'storage://expense-evidence/w/u/r1.pdf',
        'attachment_skipped': false,
        'skip_reason': null,
        'recorded_by_name': 'مشغل البئر',
      },
      {
        // مصروف معلّق بتخطٍ صريح بسبب.
        'id': 'expense-p2',
        'well_id': wellId,
        'category_code': 'maintenance',
        'category_name': 'صيانة',
        'amount_minor': 45000,
        'description': 'إصلاح لوحة تحكم',
        'status': 'pending_approval',
        'spent_at': today.toIso8601String(),
        'payment_source': 'cashbox',
        'attachment_url': null,
        'attachment_skipped': true,
        'skip_reason': 'المحل لا يصدر فواتير ورقية',
        'recorded_by_name': 'مشغل البئر',
      },
      {
        // مصروف تاريخي بمرفق — بطاقة «مرفق سند» وزر العرض.
        'id': 'expense-h1',
        'well_id': wellId,
        'category_code': 'diesel',
        'category_name': 'ديزل',
        'amount_minor': 120000,
        'description': 'ديزل جلسة سقي',
        'status': 'posted',
        'spent_at': today.toIso8601String(),
        'payment_source': 'cashbox',
        'attachment_url': 'storage://expense-evidence/w/u/r2.pdf',
        'attachment_skipped': false,
        'skip_reason': null,
        'recorded_by_name': 'مشغل البئر',
      },
    ];
    if (status != null) {
      return rows
          .where((row) => row['status'] == status)
          .map(ExpenseItem.fromJson)
          .toList(growable: false);
    }
    return rows.map(ExpenseItem.fromJson).toList(growable: false);
  }

  @override
  Future<List<ExpenseCategoryItem>> fetchExpenseCategories(
    String wellId,
  ) async {
    if (failCategories) {
      throw StateError('فشل الاتصال بالخادم');
    }
    if (emptyCategories) return const [];
    return const [
      ExpenseCategoryItem(
        code: 'diesel',
        nameAr: 'ديزل',
        attachmentRequired: true,
        requiresApproval: false,
        sortOrder: 10,
      ),
      ExpenseCategoryItem(
        code: 'salaries',
        nameAr: 'رواتب واجور',
        attachmentRequired: false,
        requiresApproval: false,
        sortOrder: 50,
      ),
    ];
  }

  @override
  Future<String> uploadExpenseEvidence({
    required String wellId,
    required String localPath,
    required String fileName,
  }) async {
    uploadCalls += 1;
    callOrder.add('upload');
    if (failUpload) {
      throw StateError('فشل رفع الإثبات');
    }
    return 'storage://expense-evidence/$wellId/user-1/$fileName';
  }

  @override
  Future<void> recordExpense({
    required String wellId,
    required String categoryCode,
    required int amountYER,
    required String description,
    String paymentSource = 'cashbox',
    String? partnerId,
    String? attachmentUrl,
    bool attachmentSkipped = false,
    String? skipReason,
    String? note,
  }) async {
    saveCalls += 1;
    callOrder.add('save');
    lastCategoryCode = categoryCode;
    lastSkipReason = skipReason;
    lastNote = note;
    lastSkipped = attachmentSkipped;
    lastAttachmentUrl = attachmentUrl;
    if (failSave) {
      throw StateError('فشل حفظ المصروف');
    }
  }

  @override
  Future<String> resolveAttachmentViewUrl(String attachmentUrl) async {
    resolveCalls += 1;
    return 'https://signed.example/expense-evidence/r.pdf?token=1';
  }

  @override
  Future<void> decideExpense({
    required String expenseId,
    required bool approve,
    String? note,
  }) async {}
}

/// منصة اختيار مزيَّفة: تعيد ملفًا محددًا مسبقًا بلا قنوات نظام.
class _FakePickerPlatform extends FilePickerPlatform {
  _FakePickerPlatform(this.files);
  final List<PlatformFile> files;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
  }) async {
    return files;
  }
}

/// ملف مختار مزيَّف: مسار محلي حقيقي الشكل بلا قراءة فعلية.
base class _FakePickedFile extends PlatformFile {
  _FakePickedFile()
    : _name = 'receipt-101.pdf',
      _uri = Uri(path: '/tmp/cache/receipt-101.pdf', scheme: 'file');

  final String _name;
  final Uri _uri;

  @override
  String get name => _name;

  @override
  Uri get uri => _uri;

  @override
  XFile get xFile => XFile(_uri.toFilePath());

  @override
  int? lengthSync() => 2048;

  @override
  Future<int> length() async => 2048;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List.fromList(const [1, 2]);

  @override
  Stream<Uint8List> readAsByteStream() =>
      Stream.value(Uint8List.fromList(const [1, 2]));
}

final PlatformFile _fakePdfFile = _FakePickedFile();

Future<void> _pumpScreen(
  WidgetTester tester, {
  required _FakeExpensesRepository repository,
  List<String> roles = const ['owner'],
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      home: ExpensesScreen(
        identity: testIdentity(
          wells: [testWell(roles: roles)],
        ),
        repository: repository,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openRecordDialog(WidgetTester tester) async {
  await tester.tap(find.text('تسجيل مصروف'));
  await tester.pumpAndSettle();
}

/// تعبئة الحقول النصية الإلزامية (المبلغ والبيان) وحدها.
Future<void> _fillMandatoryFields(WidgetTester tester) async {
  await tester.enterText(
    find.widgetWithText(CurrencyTextFormField, 'المبلغ (ريال يمني) *'),
    '5000',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'بيان وتفاصيل المصروف *'),
    'شراء لوح طاقة',
  );
}

void main() {
  setUp(() {
    FilePickerPlatform.instance = _FakePickerPlatform([_fakePdfFile]);
  });

  group('ExpensesScreen Tests (ق-131 بند 13 / هجرة 111)', () {
    testWidgets(
      '1. الشاشة والتبويبات والملخص تعمل كما هي',
      (tester) async {
        final repo = _FakeExpensesRepository();
        await _pumpScreen(tester, repository: repo);

        expect(find.textContaining('اليوم'), findsWidgets);
        expect(find.textContaining('بانتظار الاعتماد'), findsWidgets);
        expect(find.textContaining('السجل'), findsWidgets);
        expect(find.text('تسجيل مصروف'), findsOneWidget);
      },
    );

    testWidgets(
      '2. الفئات تُحمَّل من الخادم: أكواد حية لا خريطة ملفقة',
      (tester) async {
        final repo = _FakeExpensesRepository();
        await _pumpScreen(tester, repository: repo);
        await _openRecordDialog(tester);

        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('ديزل'),
          ),
          findsOneWidget,
        );
        expect(find.text('ديزل ووقود'), findsNothing);
      },
    );

    testWidgets(
      '3. فشل تحميل الفئات: فشل صريح مع إعادة محاولة ولا بديل ملفق',
      (tester) async {
        final repo = _FakeExpensesRepository(failCategories: true);
        await _pumpScreen(tester, repository: repo);
        await _openRecordDialog(tester);

        expect(
          find.text('تعذر تحميل فئات المصروفات من الخادم'),
          findsOneWidget,
        );
        expect(find.text('إعادة المحاولة'), findsOneWidget);
        expect(find.text('ديزل ووقود'), findsNothing);
        expect(find.text('كهرباء وطاقة'), findsNothing);
      },
    );

    testWidgets(
      '4. فئات الخادم الفارغة: حالة غياب صريحة لا فئات ملفقة',
      (tester) async {
        final repo = _FakeExpensesRepository(emptyCategories: true);
        await _pumpScreen(tester, repository: repo);
        await _openRecordDialog(tester);

        expect(
          find.text('لا توجد فئات مصروفات مفعّلة لهذه الجهة على الخادم'),
          findsOneWidget,
        );
        expect(find.text('ديزل ووقود'), findsNothing);
      },
    );

    testWidgets(
      '5. الخياران حصريان: اختيار ملف يمسح التخطي، والتخطي يمسح الملف',
      (tester) async {
        final repo = _FakeExpensesRepository();
        await _pumpScreen(tester, repository: repo);
        await _openRecordDialog(tester);

        await tester.tap(find.text('إرفاق سند / فاتورة'));
        await tester.pumpAndSettle();
        expect(find.textContaining('receipt-101.pdf'), findsOneWidget);

        await tester.tap(find.text('تخطي إرفاق صورة السند / الفاتورة'));
        await tester.pumpAndSettle();
        expect(find.textContaining('receipt-101.pdf'), findsNothing);

        await tester.tap(find.text('تخطي إرفاق صورة السند / الفاتورة'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('إرفاق سند / فاتورة'));
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(TextFormField, 'سبب عدم توفر المرفق *'),
          findsNothing,
        );
        expect(find.textContaining('receipt-101.pdf'), findsOneWidget);
      },
    );

    testWidgets(
      '6. لا حفظ بلا إثبات: لا ملف ولا تخطٍ يمنعان الإرسال',
      (tester) async {
        final repo = _FakeExpensesRepository();
        await _pumpScreen(tester, repository: repo);
        await _openRecordDialog(tester);
        await _fillMandatoryFields(tester);

        await tester.tap(find.text('حفظ المصروف'));
        await tester.pumpAndSettle();

        expect(repo.saveCalls, 0);
        expect(
          find.textContaining('أرفق سند/فاتورة أو تخطَّ الإرفاق'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '7. مسار التخطي: سبب غير فارغ إلزامي ويُرسل في عموده لا في الملاحظة',
      (tester) async {
        final repo = _FakeExpensesRepository();
        await _pumpScreen(tester, repository: repo);
        await _openRecordDialog(tester);
        await _fillMandatoryFields(tester);

        await tester.tap(find.text('تخطي إرفاق صورة السند / الفاتورة'));
        await tester.pumpAndSettle();

        // سبب أبيض يُحجب بواسطة المدقق.
        await tester.enterText(
          find.widgetWithText(TextFormField, 'سبب عدم توفر المرفق *'),
          '   ',
        );
        await tester.tap(find.text('حفظ المصروف'));
        await tester.pumpAndSettle();
        expect(repo.saveCalls, 0);

        await tester.enterText(
          find.widgetWithText(TextFormField, 'سبب عدم توفر المرفق *'),
          'المحل لا يصدر فواتير ورقية',
        );
        await tester.tap(find.text('حفظ المصروف'));
        await tester.pumpAndSettle();

        expect(repo.saveCalls, 1);
        expect(repo.uploadCalls, 0);
        expect(repo.lastSkipped, true);
        expect(repo.lastSkipReason, 'المحل لا يصدر فواتير ورقية');
        // السبب لا يُطوى في الملاحظة: note مستقلة بلا أي إلحاق.
        expect(repo.lastNote, isNull);
      },
    );

    testWidgets(
      '8. مسار الإرفاق: الرفع يسبق الحفظ، وskipped=false والسبب null',
      (tester) async {
        final repo = _FakeExpensesRepository();
        await _pumpScreen(tester, repository: repo);
        await _openRecordDialog(tester);
        await _fillMandatoryFields(tester);

        await tester.tap(find.text('إرفاق سند / فاتورة'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('حفظ المصروف'));
        await tester.pumpAndSettle();

        expect(repo.uploadCalls, 1);
        expect(repo.saveCalls, 1);
        expect(repo.callOrder, ['upload', 'save']);
        expect(repo.lastSkipped, false);
        expect(repo.lastSkipReason, isNull);
        expect(
          repo.lastAttachmentUrl,
          'storage://expense-evidence/well-1/user-1/receipt-101.pdf',
        );
      },
    );

    testWidgets(
      '9. فشل الرفع: لا نجاح كاذب ولا حفظ بعده',
      (tester) async {
        final repo = _FakeExpensesRepository(failUpload: true);
        await _pumpScreen(tester, repository: repo);
        await _openRecordDialog(tester);
        await _fillMandatoryFields(tester);

        await tester.tap(find.text('إرفاق سند / فاتورة'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('حفظ المصروف'));
        await tester.pumpAndSettle();

        expect(repo.uploadCalls, 1);
        expect(repo.saveCalls, 0);
        expect(find.textContaining('حدث خطأ أثناء الحفظ'), findsOneWidget);
      },
    );

    testWidgets(
      '10. فشل الحفظ بعد رفع ناجح: يُعرض فشل صريح',
      (tester) async {
        final repo = _FakeExpensesRepository(failSave: true);
        await _pumpScreen(tester, repository: repo);
        await _openRecordDialog(tester);
        await _fillMandatoryFields(tester);

        await tester.tap(find.text('إرفاق سند / فاتورة'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('حفظ المصروف'));
        await tester.pumpAndSettle();

        expect(repo.uploadCalls, 1);
        expect(find.textContaining('حدث خطأ أثناء الحفظ'), findsOneWidget);
      },
    );

    testWidgets(
      '11. كود الفئة الخادمي يُرسل كما هو بعد الاختيار',
      (tester) async {
        final repo = _FakeExpensesRepository();
        await _pumpScreen(tester, repository: repo);
        await _openRecordDialog(tester);
        await _fillMandatoryFields(tester);

        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('ديزل'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('رواتب واجور').last);
        await tester.pumpAndSettle();

        await tester.tap(find.text('تخطي إرفاق صورة السند / الفاتورة'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'سبب عدم توفر المرفق *'),
          'بلا فواتير',
        );
        await tester.tap(find.text('حفظ المصروف'));
        await tester.pumpAndSettle();

        expect(repo.lastCategoryCode, 'salaries');
      },
    );

    testWidgets(
      '12. بطاقة مصروف بمرفق: «مرفق سند» و«عرض المرفق» يحل المرجع لحظيًا',
      (tester) async {
        final repo = _FakeExpensesRepository();
        await _pumpScreen(tester, repository: repo);

        await tester.tap(find.byType(Tab).at(2));
        await tester.pumpAndSettle();

        expect(find.text('مرفق سند'), findsOneWidget);
        await tester.tap(find.text('عرض المرفق'));
        await tester.pumpAndSettle();

        expect(repo.resolveCalls, 1);
        expect(find.text('مرفق السند'), findsOneWidget);
        expect(find.textContaining('signed.example'), findsOneWidget);
      },
    );

    testWidgets(
      '13. بطاقة مصروف متخطى: تعرض سبب عدم الإرفاق صريحًا بلا «غير محدد»',
      (tester) async {
        final repo = _FakeExpensesRepository();
        await _pumpScreen(tester, repository: repo);

        expect(find.text('تم تخطي المرفق'), findsOneWidget);
        expect(
          find.text('سبب عدم الإرفاق: المحل لا يصدر فواتير ورقية'),
          findsOneWidget,
        );
        expect(find.text('غير محدد'), findsNothing);
      },
    );

    testWidgets(
      '14. حوار قرار المالك لمصروف متخطى: يعرض سبب الإرفاق قبل القرار',
      (tester) async {
        final repo = _FakeExpensesRepository();
        await _pumpScreen(tester, repository: repo);

        await tester.tap(find.byType(Tab).at(1));
        await tester.pumpAndSettle();
        // الإقرار المتخطى هو الثاني في قائمة الانتظار.
        await tester.tap(find.text('مراجعة وقرار الاعتماد').at(1));
        await tester.pumpAndSettle();

        expect(find.text('مراجعة المصروف والاعتماد'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining(
              'سبب عدم الإرفاق: المحل لا يصدر فواتير',
            ),
          ),
          findsOneWidget,
        );
        expect(find.text('اعتماد المصروف'), findsOneWidget);
        expect(find.text('رفض'), findsOneWidget);
      },
    );

    testWidgets(
      '15. حوار قرار المالك لمصروف بمرفق: يعرض «مرفق سند» و«عرض المرفق»',
      (tester) async {
        final repo = _FakeExpensesRepository();
        await _pumpScreen(tester, repository: repo);

        await tester.tap(find.byType(Tab).at(1));
        await tester.pumpAndSettle();
        await tester.tap(find.text('مراجعة وقرار الاعتماد').first);
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('مرفق سند'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('عرض المرفق'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '16. مشغل يسجل مصروف cashbox بتخطٍ ولا يرى قرار الاعتماد (م109)',
      (tester) async {
        final repo = _FakeExpensesRepository();
        await _pumpScreen(
          tester,
          repository: repo,
          roles: const ['operator'],
        );

        expect(find.text('تسجيل مصروف'), findsOneWidget);
        await tester.tap(find.byType(Tab).at(1));
        await tester.pumpAndSettle();
        expect(find.text('مراجعة وقرار الاعتماد'), findsNothing);

        // مسار التخطي للمشغل يعمل ويصل للمستودع كما هو.
        await _openRecordDialog(tester);
        await _fillMandatoryFields(tester);
        await tester.tap(find.text('تخطي إرفاق صورة السند / الفاتورة'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'سبب عدم توفر المرفق *'),
          'أجور نقدية بلا فاتورة',
        );
        await tester.tap(find.text('حفظ المصروف'));
        await tester.pumpAndSettle();

        expect(repo.saveCalls, 1);
        expect(repo.lastSkipped, true);
        expect(repo.lastSkipReason, 'أجور نقدية بلا فاتورة');
      },
    );
  });
}
