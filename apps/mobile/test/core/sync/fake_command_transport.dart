/// خادم مزيَّف يسلك سلوك ق-114 حرفيًا.
///
/// يحفظ نتيجة كل `p_command_id` نفّذه، فإعادة الإرسال بنفس المعرّف
/// تُعيد **النتيجة المخزونة بلا تنفيذ ثانٍ** — تمامًا كما تفعل
/// `sync.begin_well_command` في Migration 084.
///
/// وجود هذا المزيَّف هو ما يجعل الحزمة تعمل بلا شبكة وبلا قاعدة
/// بيانات: [requests] يسجّل كل ما استُدعي به، و[executionCount] يفرّق
/// بين «أُرسل مرتين» و«نُفِّذ مرتين» — والفرق بينهما هو كل الجولة.
library;

import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';

class FakeCommandTransport implements CommandTransport {
  FakeCommandTransport({this.idPrefix = 'srv'});

  final String idPrefix;

  /// كل محاولة إرسال بترتيبها — للتحقق من ثبات المعرّف ومن الترتيب.
  final List<DispatchRequest> requests = [];

  /// النتائج المخزونة بمعرّف العملية. حجمها = عدد التنفيذات الفعلية.
  final Map<String, DispatchAccepted> executed = {};

  /// فشل مجدول لكل دالة، يُستهلك واحدًا لكل محاولة.
  final Map<String, List<DispatchResult>> failures = {};

  /// دوال ينفّذها الخادم ثم يضيع ردّها مرة واحدة.
  ///
  /// هذه هي الحالة الخطيرة: العملية جرت فعلًا والتطبيق لا يعلم.
  final Set<String> swallowAckOnce = {};

  /// يجعل `create_farmer` تُرجِع كيانًا قائمًا بدل إنشاء جديد (ق-88).
  bool matchExistingFarmer = false;

  int _seed = 0;

  @override
  Future<DispatchResult> dispatch(DispatchRequest request) async {
    requests.add(request);

    final scheduled = failures[request.type.rpcName];

    if (scheduled != null && scheduled.isNotEmpty) {
      return scheduled.removeAt(0);
    }

    if (swallowAckOnce.remove(request.type.rpcName)) {
      // الخادم نفّذ وخزَّن النتيجة، ثم انقطع الردّ في الطريق.
      executed[request.commandId] = _execute(request);

      return const DispatchFailed(
        disposition: FailureDisposition.retry,
        message: 'SocketException: connection closed before reply',
      );
    }

    final stored = executed[request.commandId];

    if (stored != null) {
      return stored;
    }

    return executed[request.commandId] = _execute(request);
  }

  /// عدد التنفيذات الفعلية — لا عدد المحاولات.
  int get executionCount => executed.length;

  List<String> get calledFunctions =>
      requests.map((request) => request.type.rpcName).toList();

  List<DispatchRequest> requestsFor(CommandType type) =>
      requests.where((request) => request.type == type).toList();

  DispatchRequest lastRequestFor(CommandType type) => requestsFor(type).last;

  void scheduleFailure(CommandType type, DispatchResult result) {
    failures.putIfAbsent(type.rpcName, () => []).add(result);
  }

  void scheduleNetworkFailure(CommandType type, {int times = 1}) {
    for (var index = 0; index < times; index += 1) {
      scheduleFailure(
        type,
        const DispatchFailed(
          disposition: FailureDisposition.retry,
          message: 'SocketException: Failed host lookup',
        ),
      );
    }
  }

  void scheduleBusinessRejection(CommandType type, {String code = 'P0001'}) {
    scheduleFailure(
      type,
      DispatchFailed(
        disposition: FailureDisposition.review,
        message: '$code: الجلسة مغلقة أصلًا',
        code: code,
      ),
    );
  }

  /// يبني ردًّا خامًا بشكل الخادم الحقيقي، ثم يمرّه على التوحيد نفسه
  /// الذي يستخدمه الإنتاج — فيُختبر التوحيد بلا كود اختبار موازٍ.
  DispatchAccepted _execute(DispatchRequest request) {
    final type = request.type;
    final id = '$idPrefix-${type.rpcName}-${++_seed}';

    if (!type.returnsJson) {
      return normalizeAcceptedResponse(type, id);
    }

    return normalizeAcceptedResponse(type, {
      type.resultKey!: id,
      if (type == CommandType.createFarmer)
        'already_exists': matchExistingFarmer,
    });
  }
}
