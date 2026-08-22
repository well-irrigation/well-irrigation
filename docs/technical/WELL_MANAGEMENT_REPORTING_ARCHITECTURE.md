# Well Management & Reporting Architecture

**آخر تحديث:** 2026-08-19
**القرار الحاكم:** ق-100
**UX:** UX-15 / 460–526
**الحالة:** تصميم تقني ملزم؛ التنفيذ الكامل Pending
**المسألة المفتوحة:** م-30
**أول DB Migration جديدة:** 085 أو أحدث

## 1. الهدف

تحديد عقود التطبيق لإدارة:

- Well.
- Pump.
- Energy.
- Fuel.
- Pricing.
- Reports.
- Simple V1 Charts.

دون إنشاء مصادر حقيقة موازية داخل Flutter.

## 2. Well

يلزم Read Model يعيد:

- well identity.
- name.
- status.
- location/description عند السماح.
- current operational state.
- active-session blocker indicators.
- setup/readiness summary عند الحاجة.

أي Write يجب أن يتحقق من عدم كسر Session قائمة.

## 3. Well archival

Hard Delete ليس عقد Flutter العادي لبئر مستخدم تاريخيًا.

أي Deactivation/Archive يجب أن يحافظ على:

- sessions.
- invoices.
- payments.
- expenses.
- bookings.
- partners.
- reports.

## 4. Pump equipment model

Migration 076 هي الأساس الحالي.

المضخة Equipment لها بيانات مثل:

- pump type.
- power rating.
- estimated fuel rate.
- estimated flow.
- installed date.
- notes.
- status.

## 5. Pump state transition

يلزم Contract يمنع حالات مثل:

    active session
        +
    retire pump

دون حل العمل الجاري.

Transitions تحتاج Server validation.

## 6. Session energy authority

Modern source:

`ops.session_segments.energy_source`

Allowed:

- solar.
- well_diesel.
- farmer_diesel.

`core.pumps.power_source` ليس الحقيقة الحديثة.

## 7. Reporting energy

Report Aggregation للجلسات الحديثة يستخدم:

- segment energy source.
- segment billable seconds.

Legacy fallback يستخدم Pump Power Source فقط عندما لا توجد
Segments تاريخية.

## 8. Fuel inventory foundation

الموجود حاليًا:

- fuel tanks.
- well fuel.
- farmer fuel.
- purchases.
- consumption.
- returns.
- adjustments.
- physical counts.
- actual/estimated measurement.
- moving average cost.

هذا يعاد استخدامه.

## 9. Fuel read contracts

Flutter تحتاج Typed Reads لـ:

- tanks.
- current balance.
- pending estimated quantity.
- recent transactions.
- daily consumption aggregation.
- physical-count differences.

## 10. Fuel write contracts

تستخدم/تستكمل `api.*` لـ:

- purchase.
- consumption.
- physical count.
- farmer fuel movements حسب الحاجة.
- audited adjustments.

## 11. Fuel reconciliation

Physical Count:

    recorded balance
      vs
    measured balance

ينتج Difference.

لا تستخدم Flutter Direct Update للرصيد.

يلزم Audited Adjustment.

## 12. Fuel billing separation

Fuel operational cost لا يعني Farmer Fuel Surcharge.

ق-17 وق-91 أعلى أولوية.

Any old contract allowing separate Farmer Fuel Charge must
not be used by V1 Flutter.

## 13. Pricing foundation

`ops.price_schedules`:

- effective period.
- status.
- reason.
- approval context.

`ops.price_rules`:

- energy source.
- hourly rates.
- legacy diesel pricing models.

## 14. Pricing target

V1 target:

    inclusive_hourly

للديزل.

`operation_plus_fuel` Legacy/Conflict.

لا يظهر في Flutter.

إذا احتاج DB restriction:

Migration 085+.

## 15. Historical pricing

New Price Schedule لا يعيد كتابة القديم.

Session calculation يجب أن يستخدم Trusted Price Snapshot
حسب Event Time/Segment policy الحاكمة.

## 16. Pricing Offline

Trusted cached snapshot:

يمكن استخدامها وفق ق-89.

إذا لم توجد:

    Pricing Pending

ولا Guess.

## 17. Reporting foundation

الموجود داخليًا يشمل:

- farmer account balances.
- cashbox balances.
- fuel balances.
- partner account summary.
- well daily summary.

Migration 076 صححت Energy Attribution الحديثة.

هذه Views ليست دعوة إلى Direct Flutter aggregation.

## 18. Public reporting contracts

Flutter تحتاج `api.*` Read Models مثل:

- report overview.
- irrigation trend.
- financial trend.
- energy breakdown.
- fuel trend.
- pump usage.
- operator usage.
- partner own profit trend.

الأسماء النهائية تحسم أثناء التنفيذ.

## 19. Report period

العقد يقبل Range واضحة.

يجب تحديد Timezone/Day Boundary بصورة صريحة.

لا يعتمد على PostgreSQL Session Timezone بطريق الصدفة.

## 20. End-day attribution

القرار الحالي:

Closed/Forgotten Session تنسب إلى يوم انتهائها في
التقرير اليومي.

أي Read Model جديد يجب أن يحافظ على القرار أو ينسخه
بقرار صريح.

## 21. Chart philosophy

Chart Presentation فقط.

لا تستخدم Chart computation كمصدر Business Truth.

Pipeline:

    canonical business data
        ↓
    server aggregation
        ↓
    typed report response
        ↓
    Flutter chart rendering

## 22. V1 chart types

فقط:

- Bar.
- Line.

الهدف:

- implementation أصغر.
- testing أسهل.
- mobile readability أعلى.
- accessibility أبسط.

## 23. Owner Home

لا Chart في V1.

هذا قرار UX وليس نقصًا تقنيًا.

الرئيسية تظل Action-oriented.

## 24. Reports Main Chart

بعد Summary Metrics:

يعرض Chart واحدة.

Metric selector يستطيع اختيار مثلًا:

- irrigation hours.
- collections.
- expenses.
- fuel consumption.

لا تعرض كل الرسوم دفعة واحدة.

## 25. Irrigation chart

Metric:

    billable irrigation hours per day

Source:

Canonical session/report aggregation.

Type:

Bar.

## 26. Financial chart

Metrics:

- collected.
- expenses.

Type:

Line.

Both share YER unit.

لا نضع Sessions Count على نفس Y axis.

## 27. Energy chart

Metrics:

- solar hours.
- well diesel hours.
- farmer diesel hours.

Type:

Bar.

Modern data تأتي من Segments.

## 28. Fuel chart

Mini Fuel Chart:

- location: Fuel page.
- period: last 7 days.
- metric: consumption.

Full Fuel Report:

- selected period.
- daily consumption.

Current balance يبقى Numeric Card منفصلًا.

## 29. Pump chart

Metric:

    billable/operational hours by pump

Type:

Bar.

Historical retired pump يمكن أن تظهر في Historical Report.

## 30. Operator chart

Metric selector يمكن أن يكون:

- session count.
- billable hours.

Type:

Bar.

لا تعرض Financial Partner Data هنا.

## 31. Partner chart

Partner projection:

    own net payable by distribution cycle

Default:

آخر 6 دورات متاحة.

لا يعيد API Partner Lines لشركاء آخرين إذا لم يسمح دوره.

## 32. Chart interaction

Tap على element يعرض:

- exact value.
- unit.
- period/category.

عندما يوجد Source List:

يوفر Drill-down.

## 33. Empty data

No Data:

لا تولد Zero Series مصطنعة.

Response/UI تعرض Empty State.

## 34. Offline/Stale

Cached Report يجب أن يحمل ما يسمح بعرض:

- generated/as-of time.
- last sync.
- stale indicator.

Chart نفسها لا توصف Live إذا كانت Cached.

## 35. Chart accessibility

Rendering يجب أن يوفر:

- textual title.
- numerical summary.
- non-color distinction where needed.
- readable labels.
- exact-value interaction.

Chart لا تكون الطريق الوحيد لفهم البيانات.

## 36. Chart density

Mobile V1:

- one primary large chart at a time.
- one mini contextual chart where adopted.
- no dashboard wall of charts.

## 37. Performance

Server aggregation يجب أن يمنع تحميل آلاف Raw Records
فقط لرسم 7 أو 30 نقطة.

Default chart data should be period-aggregated.

## 38. Permissions

Owner:

broad reports.

Operator:

operational projection only.

Partner:

allowed well context + own financial projection.

Backend authorization remains final.

## 39. Required API work

Migration 085+ أو Server changes قد تحتاج:

1. well summary/read.
2. well update.
3. pump list/detail.
4. pump safe-state update.
5. fuel list/summary.
6. fuel adjustment.
7. pricing read.
8. pricing version creation.
9. block legacy diesel model from V1 contract.
10. reporting overview.
11. irrigation chart series.
12. financial chart series.
13. energy chart series.
14. fuel chart series.
15. pump chart series.
16. operator chart series.
17. partner own-profit series.
18. timezone-safe period handling.

## 40. Acceptance tests

### Well/Pump

- historical well not hard deleted.
- pump with active session cannot unsafe-retire.
- maintenance pump excluded from normal new selection.
- historical reports still identify retired pump.

### Energy

- multi-source session reports each source correctly.
- legacy session fallback remains correct.
- Pump Power Source never overrides modern Segments.

### Fuel

- well/farmer balances separate.
- estimated measurement visibly/statefully pending.
- physical count difference preserved.
- adjustment audited.
- negative balance rejected.
- retry does not duplicate Fuel Movement.

### Pricing

- new price version does not alter historical session.
- diesel V1 uses inclusive hourly.
- `operation_plus_fuel` unavailable to Flutter.
- no minimum billing block.
- Pricing Pending works Offline.

### Reports

- period boundaries correct in configured timezone.
- closed session attributed according to End Day rule.
- summary totals match source records.
- partner projection leaks no private other-partner data.
- operator report contains no unauthorized finance.

### Charts

- 7-day irrigation series matches report totals.
- financial collections/expenses use same units.
- energy series comes from segments.
- empty range returns empty state.
- stale data exposes timestamp.
- drill-down total matches chart point.
- no chart requires color alone.
- Partner chart returns own cycles only.

## 41. Definition of Done

UX-15 لا تعتبر Production Complete حتى:

- م-30 مغلقة.
- safe Well/Pump contracts مثبتة.
- energy attribution مثبت.
- fuel contracts/reconciliation مثبتة.
- pricing history مثبت.
- diesel conflict مغلق.
- report read models مثبتة.
- timezone policy مثبتة.
- chart aggregations مثبتة.
- role projections مثبتة.
- Offline/Stale behavior مثبت.
- accessibility مثبتة.
- Backend permanent tests ناجحة.
- Android field tests ناجحة.
