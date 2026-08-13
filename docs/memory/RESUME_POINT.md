# نقطة الاستئناف

اخر تحديث: 2026-08-13 (نهاية المرحلة 4)

## الحالة
- الفرع main، المستودع well-irrigation/well-irrigation (خاص).
- الهجرات المطبقة: 46 (001 الى 046). عدد الجداول: 49.
- المراحل المكتملة: 1 النواة (ق-68)، 2 التشغيل (ق-69)، 3 المال (ق-70)، 4 الديزل والمصروفات (ق-71 و ق-72).
- الاختبارات الوظيفية: 19/19 للمرحلة 3، و27/27 ثم 25/25 للمرحلة 4، بصفر فشل.

## الاوامر الاساسية
- الدخول للمشروع: cd /home/kali/pr/well-irrigation
- اعادة بناء القاعدة: npm run db:reset
- معرف حاوية القاعدة: DBC=(docker ps --filter name=supabase_db -q | head -1) داخل تعويض امر
- الاتصال: docker exec -i "DBC" psql -U postgres -d postgres -v ON_ERROR_STOP=1

## التالي: المرحلة 5 الشركاء
حسب ترتيب البناء المعتمد في docs/reference/02_database_and_finance_design.md القسم 47:
1. core.well_partners وحصص الشركاء.
2. core.partner_irrigation_policies وربطها بـ billing.invoices.partner_policy_id.
3. الفترات المحاسبية والاقفال.
4. الخطوة 5 المؤجلة من القسم 32 داخل finance.post_journal_entry.
5. القيود المحاسبية لحركات الديزل: مخزون ثم تكلفة مستهلكة، حسب القسم 26.

## اعمال مؤجلة معروفة
- تنبيه shift_open_too_long: 12 ساعة للمشغل و16 للمالك.
- توحيد inventory.fuel_purchases.liters مع الكميات بالمليلتر.
- العمود القديم payments.received_by_profile_id موقوف الاستخدام.
- م-15 و م-16 و م-18 و م-19 وحاجز الجلسة المفتوحة المكررة.
