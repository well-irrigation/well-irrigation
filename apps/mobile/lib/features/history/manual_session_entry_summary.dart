import 'package:flutter/material.dart';

import '../../core/sync/manual_session_entry.dart';

String manualEntryTime(DateTime time) {
  final v = time.toLocal();
  return '${v.year}/${v.month}/${v.day}  ${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}';
}

String manualEntryStatus(ManualSessionEntryFollowUp view) =>
    switch (view.eligibility) {
      ManualEntryCorrectionEligibility.eligibleTerminalNoSession =>
        'لم تتم الإضافة',
      ManualEntryCorrectionEligibility.ineligibleSessionExists => 'تمت الإضافة',
      _ => 'بياناتك محفوظة. تابع حالة الإضافة',
    };

/// تعريف الجلسة من حقائق الطلب فقط؛ لا يعرض المعرّفات ولا يخمّن الأسماء.
class ManualSessionEntrySummary extends StatelessWidget {
  const ManualSessionEntrySummary({
    super.key,
    required this.facts,
    this.farmerName,
    this.farmName,
    this.pumpName,
  });
  final ManualSessionEntryFacts facts;
  final String? farmerName, farmName, pumpName;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        facts.endedAt == null ? 'جلسة ما زالت جارية' : 'جلسة منتهية',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      Text('بدأت: ${manualEntryTime(facts.startedAt)}'),
      if (facts.endedAt case final end?) Text('انتهت: ${manualEntryTime(end)}'),
      if (farmerName != null) Text('المزارع: $farmerName'),
      if (farmName != null) Text('الأرض: $farmName'),
      if (pumpName != null) Text('المضخة: $pumpName'),
      Text(
        'السبب: ${facts.reason}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      if (facts.notes case final notes? when notes.trim().isNotEmpty)
        Text('ملاحظات: $notes', maxLines: 2, overflow: TextOverflow.ellipsis),
    ],
  );
}
