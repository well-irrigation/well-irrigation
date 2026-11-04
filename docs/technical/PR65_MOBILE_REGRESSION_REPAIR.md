# PR #65 — مصالحة اختبارات الهاتف وحدود سلطة الحجز

الحالة: IMPLEMENTED + VERIFIED محليًا؛ COMMIT/PUSH NOT_RUN.
الفرع: `reconcile/q137-local-20261030`.
رأس الأساس: `262846b2643d6c60f377829e4a7238279a72b8fa`.
الدفعة غير ملتزم بها؛ لا stage أو commit أو push أو تحقق سحابي.

## العقد الحاكم والتنفيذ

هذه مصالحة مع ق-137 وR6-A والثوابت الحاكمة؛ لا قرار منتج جديد.
حفظ الحجز يحفظ طلبًا محليًا دائمًا ولا يعني قبول الخادم أو تشغيل السقي.
طلب إنهاء الجلسة يبقي هويتها والإشغال قائمين حتى وصول إيصال قبول صحيح.
النتيجة الغامضة تُستعاد بإيصالها مع المعرّف والوقت الأصليين، دون إعادة
إرسال عمياء أو تلفيق اكتمال أو مال.

أُصلح في `apps/mobile/lib/features/operations/operations_screen.dart`:

- تعطيل تسليح المؤقّت والاستدعاءات المؤجلة لمسارات الانتقال التشغيلي
  القديمة؛ وقت الحجز للتذكير ولا ينشئ أمر بدء أو إنهاء. لا يعاد تفعيل
  المسار بمجرد تحديث الجدول أو العودة من الخلفية أو إعادة بناء الشاشة.
- قبول إنهاء **نفس جذر الجلسة المحلية المعروضة** يصفّر نموذج تشغيلها
  ويوقف عدادها؛ لا يمحو إيصال متأخر لجلسة قديمة جلسة أحدث. يبقى ملخص
  الإنهاء والدفع قابلًا للعرض من نتيجة الخادم، لا من طلب الإنهاء وحده.

لا تغيير لخادم R6-C0/C1/C2/C3 أو المال أو أولوية الديون أو صلاحياتها.
لا تعديلات هجرات. لا يُثبت هذا الإصلاح تنفيذ واجهات R6 المالية المؤجلة،
أو قبول جهاز فعلي، أو تفعيلًا عامًا، أو نشرًا إنتاجيًا.

## تصنيف الفشل الأصلي

67 إخفاقًا محليًا مطابقًا لعدد CI الأصلي؛ التصنيف الأساسي لكل حالة
واحد، مع وجود حالات تحتاج أكثر من تصحيح في تجهيزها:

| ملف الاختبار (تحت `apps/mobile/test/`) | العدد الأصلي | التصنيف الأساسي | سبب المصالحة |
|---|---:|---|---|
| `core/booking/booking_ack_test.dart` | 1 | STALE_TEST_EXPECTATION | «جاري» قبل قبول الإنهاء؛ «منفذ» بعد الإيصال فقط؛ تثبيت الفعل البشري ومرجع الجذر |
| `core/sync/farmer_identity_resolution_test.dart` | 1 | TEST_FIXTURE_DEFECT | إثبات فعل البدء البشري مع بقاء حسم الهوية والأوامر التابعة |
| `core/sync/sqlite_outbox_store_test.dart` | 1 | TEST_FIXTURE_DEFECT | حفظ أفعال الإنسان قبل إغلاق SQLite وإعادة فتحه |
| `core/sync/package_a_end_chain_test.dart` | 6 | RESTORED_HISTORY_CONTRACT_MISMATCH | بقاء أوامر السلسلة المعتزلة معلّقة وتاريخ الرفض محفوظًا؛ البئر الآخر يعمل |
| `core/sync/command_contract_test.dart` | 3 | RESTORED_HISTORY_CONTRACT_MISMATCH | بيانات الأنواع التاريخية لا تعني إتاحة إرسالها أو إنشاء كيان منها |
| `core/sync/package_a_sqlite_upgrade_test.dart` | 2 | SQLITE_UPGRADE_FIXTURE_DEFECT | فعل بشري قبل إفساد المتطلب، عزل البئر الآخر، واسترجاع ACK المفقود بالإيصال دون إعادة إرسال |
| `core/session/package_a_booked_lifecycle_test.dart` | 10 | RESTORED_HISTORY_CONTRACT_MISMATCH | لا خلف يعمل أو إكمال معتمد من مؤقت/طلب إيقاف؛ حفظ الجذر والوقت والمضخة وإعادة الفتح |
| `core/session/stale_server_booking_link_reconciliation_test.dart` | 1 | SQLITE_UPGRADE_FIXTURE_DEFECT | فحص نسخة المخزن الحالية بدل افتراض نسخة تاريخية؛ مقارنة الصفوف المحفوظة باقية |
| `core/session/package_a_transition_test.dart` | 3 | RESTORED_HISTORY_CONTRACT_MISMATCH | الصفوف القديمة ليست إثبات تنفيذ بشري، ولا تبيح إرسال الخلف أو اختلاق جلسة وحيدة |
| `features/operations/operations_crops_test.dart` | 6 | TEST_FIXTURE_DEFECT | واجهة بحث الأرض الحالية ونطاق المزارع الصحيح |
| `features/operations/operations_payment_reminder_test.dart` | 7 | TEST_FIXTURE_DEFECT | تجهيز إيصال إنهاء كامل عبر الحد الذري المعتمد |
| `features/operations/package_a_live_session_test.dart` | 1 | STALE_TEST_EXPECTATION | طلب الإنهاء لا يخفي ضوابط جلسة لم يقبل الخادم إنهاءها |
| `features/operations/operations_failure_paths_test.dart` | 1 | TEST_FIXTURE_DEFECT | تجهيز قراءات المزارع والمضخة كي لا يحجب تنبيه تحميل آخر رسالة فشل الكتابة |
| `features/operations/operations_session_ux_test.dart` | 6 | TEST_FIXTURE_DEFECT | البحث الحالي وإيصال قبول صريح قبل ملخص الدفع؛ فحص تصفير النموذج بعد القبول |
| `features/operations/package_a_manual_booking_test.dart` | 1 | STALE_TEST_EXPECTATION | البدء اليدوي وACK يبقيان هويتهما؛ مرور الموعد لا ينشئ انتقالًا |
| `features/operations/reactive_cross_screen_test.dart` | 1 | STALE_TEST_EXPECTATION | فعل إنهاء صريح، ثم إيصال، ثم بدء يدوي جديد؛ لا ACK بهوية مختلفة ولا إكمال تلقائي |
| `features/operations/operations_pricing_test.dart` | 1 | TEST_FIXTURE_DEFECT | فصل السعر التقديري عن قبول الإنهاء قبل فتح الدفع |
| `features/bookings/reactive_bookings_screen_test.dart` | 1 | STALE_TEST_EXPECTATION | ظهور الطلب المحلي فور الحفظ مستقل عن القائمة المعتمدة والإلغاء الخادمي |
| `features/bookings/booking_form_screen_test.dart` | 7 | STALE_TEST_EXPECTATION | الحفظ المحلي الدائم لا ينتظر RPC مباشرًا؛ تجهيز SQLite وبحث الأرض الصحيح |
| `features/history/session_detail_layout_test.dart` | 2 | TEST_FIXTURE_DEFECT | إيصال إنهاء كامل قبل أهلية دفع لاحقة |
| `features/history/session_detail_deferred_payment_test.dart` | 5 | TEST_FIXTURE_DEFECT | دليل إنهاء مقبول قبل استعادة الدفع وحالاته |

المجموع: 22 تاريخ عقد مستعاد، 12 توقعًا قديمًا، 30 تجهيز اختبار،
3 تجهيز ترقية SQLite. هذه 34 حالة ذات توقع/عقد قديم و33 حالة تجهيز.
أضيف إلى المصالحة فحص 8 حالات مؤقت/تحديث/خلفية/إعادة بناء في
`core/session/local_booking_transition_regression_test.dart` وحالتي الجدول
المباشر في `package_a_live_session_test.dart` لإثبات إغلاق مسار المؤقّت
المكتشف. لم يُحذف اختبار أو يُتخطَّ للوصول إلى النجاح.

المساعد الجديد `support/accepted_completion_fixture.dart` خاص بالاختبار:
يقدّم إيصال خادم مكتملًا عبر `reconcileCompletionReceipt`، ويربطه بنفس
الجذر ونفس البئر؛ لا يغيّر سلطة التنفيذ الإنتاجية. بيانات الترحيل
التاريخية تبقى اختبارات حفظ/استعادة، وليست إثبات إتاحة انتقال آلي حالي.

## التحقق

الجولة النهائية الكاملة بعد آخر إصلاح إنتاجي/اختباري:

```text
npm run c:app
STEP 0 pub get  SKIPPED  package-config-present
STEP 0 sqlite3  SKIPPED  shared-cache-present
STEP 1 analyze  OK       issues=0
STEP 2 test     OK       PASS=1780 FAIL=0
RESULT=SUCCESS
EXIT=0
```

السجلات المحلية: `/tmp/wi-checks/app-analyze.log` و
`/tmp/wi-checks/app-test.log`. العدد 67 أعلاه مرجع للفشل الأول، لا
نتيجة الجولة النهائية. لا اختبارات متخطاة أو معطلة في هذه الدفعة.

تعديل CI السابق في `.github/workflows/checks.yml` مستقل ومحفوظ؛
لم يُشغَّل Docker أو DB أو Supabase أو نشر من هذه الجولة. لا تدّعي
النتيجة نجاح GitHub Actions الجديد قبل تشغيله هناك. اختلاف مرجع مشروع
Supabase في التكامل منفصل ويحتاج مراجعة؛ لا تغيير لإعداد سحابي.
