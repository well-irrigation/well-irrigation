import 'dart:convert';

import '../api/booking_repository.dart';
import 'local_booking_request.dart';

/// إسقاط عرض فقط؛ هوية الطلب المحلية ليست هوية حجز تشغيلية.
List<WellBookingListItem> mergeBookingRequests(
  List<WellBookingListItem> canonical,
  List<LocalBookingRequest> requests,
) {
  final ids = canonical.map((b) => b.id).toSet();
  return [
    ...canonical,
    for (final request in requests)
      if (request.supersededByRequestId == null &&
          (request.bookingId == null || !ids.contains(request.bookingId)))
        _project(request),
  ];
}

WellBookingListItem _project(LocalBookingRequest request) {
  final p = request.payload;
  final context = jsonDecode(request.contextJson) as Map;
  return WellBookingListItem(
    id: 'local-request:${request.commandId}',
    publicCode: request.publicCode ?? '',
    farmerWellAccountId: p['p_farmer_well_account_id'] as String,
    farmerName: context['farmer_name'] as String? ?? '',
    farmId: p['p_farm_id'] is String ? p['p_farm_id'] as String : '',
    farmName: context['farm_name'] as String? ?? '',
    scheduledStart: DateTime.parse(p['p_scheduled_start'] as String),
    scheduledEnd: DateTime.parse(p['p_scheduled_end'] as String),
    scheduledDay: request.scheduledDay,
    expectedDurationMinutes: context['duration_minutes'] as int?,
    status: 'local_request',
    priority: p['p_priority'] as int? ?? 0,
    expectedEnergySource: p['p_expected_energy_source'] as String?,
    alternativeEnergySource: p['p_alternative_energy_source'] as String?,
    notes: p['p_notes'] as String?,
    localRequest: request,
  );
}
