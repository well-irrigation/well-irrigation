import 'dart:convert';

/// طلب المستخدم الأصلي؛ لا هوية حجز أو رمز عام قبل إيصال قبول صحيح.
/// النص الأصلي هو البصمة الحرفية للمحتوى، ولا تُحدّث أعمدته بعد الإدخال.
class LocalBookingRequest {
  const LocalBookingRequest({
    required this.accountId,
    required this.wellId,
    required this.requestId,
    required this.commandId,
    required this.createdLocalAt,
    required this.scheduledDay,
    required this.payloadJson,
    required this.contextJson,
    this.responseJson,
    this.reviewRequired = false,
    this.replacesRequestId,
    this.supersededByRequestId,
  });

  final String accountId;
  final String wellId;
  final String requestId;
  final String commandId;
  final DateTime createdLocalAt;
  final String scheduledDay;
  final String payloadJson;
  final String contextJson;
  final String? responseJson;
  final bool reviewRequired;
  final String? replacesRequestId;
  final String? supersededByRequestId;

  bool get needsCorrection => supersededByRequestId == null &&
      const {'conflict', 'rejected'}.contains(response?['status']);
  String? get correctionAction => !needsCorrection ? null :
      response?['status'] == 'conflict' ? 'اختيار موعد آخر' : 'تعديل الحجز';

  Map<String, Object?> get payload => Map.unmodifiable(
    Map<String, Object?>.from(jsonDecode(payloadJson) as Map),
  );
  Map<String, Object?> get rpcArguments => {
    ...payload,
    'p_command_id': commandId,
  };
  Map<String, Object?>? get response => responseJson == null
      ? null
      : Map.unmodifiable(
          Map<String, Object?>.from(jsonDecode(responseJson!) as Map),
        );

  bool get isConfirmed =>
      response?['status'] == 'confirmed' &&
      response?['booking_id'] is String &&
      (response!['booking_id'] as String).isNotEmpty &&
      response?['public_code'] is String &&
      (response!['public_code'] as String).isNotEmpty &&
      response?['well_id'] == wellId &&
      DateTime.tryParse(response?['scheduled_start']?.toString() ?? '') ==
          DateTime.tryParse(payload['p_scheduled_start']?.toString() ?? '') &&
      DateTime.tryParse(response?['scheduled_end']?.toString() ?? '') ==
          DateTime.tryParse(payload['p_scheduled_end']?.toString() ?? '');
  String? get bookingId =>
      isConfirmed ? response!['booking_id'] as String : null;
  String? get publicCode =>
      isConfirmed ? response!['public_code'] as String : null;

  /// لا يجيز هذا الطلب المحلي تشغيل السقي؛ التشغيل يبقى من قراءة حجز مؤكّد.
  bool get canStart => false;

  Map<String, Object?> toRow() => {
    'account_id': accountId,
    'well_id': wellId,
    'request_id': requestId,
    'command_id': commandId,
    'created_local_at': createdLocalAt.toUtc().toIso8601String(),
    'scheduled_day': scheduledDay,
    'payload': payloadJson,
    'display_context': contextJson,
    'response': responseJson,
    'replaces_request_id': replacesRequestId,
    'superseded_by_request_id': supersededByRequestId,
  };

  factory LocalBookingRequest.fromRow(Map<String, Object?> row) =>
      LocalBookingRequest(
        accountId: row['account_id'] as String,
        wellId: row['well_id'] as String,
        requestId: row['request_id'] as String,
        commandId: row['command_id'] as String,
        createdLocalAt: DateTime.parse(row['created_local_at'] as String),
        scheduledDay: row['scheduled_day'] as String,
        payloadJson: row['payload'] as String,
        contextJson: row['display_context'] as String,
        responseJson: row['response'] as String?,
        reviewRequired: row['review_required'] == 1,
        replacesRequestId: row['replaces_request_id'] as String?,
        supersededByRequestId: row['superseded_by_request_id'] as String?,
      );
}
