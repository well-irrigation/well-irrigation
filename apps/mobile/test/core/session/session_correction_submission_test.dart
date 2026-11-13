import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import '../sync/fake_command_transport.dart';

const _reason = 'تصحيح وقت التشغيل الفعلي';
final _start = DateTime.parse('2026-11-08T05:30:00+03:00');
final _end = DateTime.parse('2026-11-08T07:45:00+03:00');
const _payload = <String, Object?>{
  'p_session_id': 'server-session-1',
  'p_base_revision': 3,
  'p_reason': _reason,
  'p_desired_started_at': '2026-11-08T02:30:00.000Z',
  'p_desired_ended_at': '2026-11-08T04:45:00.000Z',
};

// لا تملك هذه البوابة هوية الأمر أو وقت طلبه؛ المصدر هو المستودع.
Future<CommandEnvelope> _submit(
  OfflineSessionCoordinator coordinator, {
  String reason = _reason,
}) => coordinator.submitSessionCorrection(
  accountId: 'account-a',
  wellId: 'well-a',
  sessionId: 'server-session-1',
  baseRevision: 3,
  reason: reason,
  desiredStartedAt: _start,
  desiredEndedAt: _end,
);

void _facts(CommandEnvelope command) {
  expect(command.type, CommandType.correctIrrigationSession);
  expect(command.accountId, 'account-a');
  expect(command.wellId, 'well-a');
  expect(command.payload, _payload);
  expect(command.aggregateLocalId, isNull);
  expect(command.prerequisites, isEmpty);
  expect(command.localContext, isEmpty);
}

void _sameIntent(CommandEnvelope actual, CommandEnvelope original) {
  expect(actual.localId, original.localId);
  expect(actual.commandId, original.commandId);
  expect(actual.occurredAt, original.occurredAt);
  expect(actual.payload, original.payload);
  expect(actual.accountId, original.accountId);
  expect(actual.wellId, original.wellId);
}

// يضيف فحص ترتيب فقط إلى النقل الوهمي القائم، دون محاكاة عقد إيصال آخر.
class _PersistenceProbeTransport extends FakeCommandTransport {
  _PersistenceProbeTransport(this.store);
  final InMemoryOutboxStore store;
  final observed = Completer<CommandEnvelope>();
  final response = Completer<DispatchResult>();

  @override
  Future<DispatchResult> dispatch(DispatchRequest request) async {
    requests.add(request);
    try {
      expect(request.type, CommandType.correctIrrigationSession);
      final saved = (await store.allCommands('account-a')).single;
      _facts(saved);
      expect(saved.status, CommandStatus.dispatching);
      expect(request.accountId, saved.accountId);
      expect(request.commandId, saved.commandId);
      expect(request.arguments, {
        ...saved.payload,
        'p_command_id': saved.commandId,
        'p_requested_at': saved.occurredAt.toUtc().toIso8601String(),
      });
      observed.complete(saved);
    } catch (error, stack) {
      observed.completeError(error, stack);
    }
    return response.future;
  }

  void release() {
    if (!response.isCompleted) {
      response.complete(
        const DispatchFailed(
          disposition: FailureDisposition.retry,
          message: 'offline_after_durable_save',
        ),
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InMemoryOutboxStore store;
  late OfflineSessionCoordinator coordinator;
  _PersistenceProbeTransport? probe;

  setUp(() async {
    store = InMemoryOutboxStore();
    await store.initialize();
    coordinator = OfflineSessionCoordinator(store: store);
    probe = null;
  });
  tearDown(() async {
    probe?.release();
    // فرصة إنهاء الإرسال والإسقاط الخلفي قبل إغلاق الموارد.
    await Future<void>.delayed(Duration.zero);
    coordinator.dispose();
    await store.close();
  });

  void configure({
    Future<bool> Function(String)? scheduler,
    CommandTransport? transport,
  }) {
    coordinator.dispose();
    coordinator = OfflineSessionCoordinator(
      store: store,
      commandQueuedScheduler: scheduler,
      commandTransport: transport,
    );
  }

  Future<CommandEnvelope> saved() async =>
      (await store.allCommands('account-a')).single;

  test('A durable correction exists before scheduler notification', () async {
    final atScheduler = Completer<CommandEnvelope>();
    configure(
      scheduler: (account) async {
        // _triggerSync يبتلع خطأ الجدولة؛ ننقل فشل الفحص إلى الاختبار صراحة.
        try {
          expect(account, 'account-a');
          final rows = await store.pendingCommands(account);
          expect(rows, hasLength(1));
          final row = rows.single;
          _facts(row);
          expect(
            row.status,
            isIn([CommandStatus.pending, CommandStatus.dispatching]),
          );
          atScheduler.complete(row);
        } catch (error, stack) {
          atScheduler.completeError(error, stack);
        }
        return true;
      },
    );
    final returned = await _submit(coordinator);
    final observed = await atScheduler.future.timeout(
      const Duration(seconds: 2),
    );
    _sameIntent(returned, observed);
    _sameIntent(
      (await store.commandByLocalId('account-a', returned.localId))!,
      returned,
    );
    expect(await store.allCommands('account-a'), hasLength(1));
  });

  test(
    'B absent transport and scheduler still return a durable pending intent',
    () async {
      final returned = await _submit(coordinator);
      _facts(returned);
      expect(returned.status, CommandStatus.pending);
      _sameIntent(await saved(), returned);
      expect((await saved()).status, CommandStatus.pending);
    },
  );

  test(
    'C scheduler exception cannot turn durable save into submission failure',
    () async {
      var calls = 0;
      CommandEnvelope? atScheduler;
      configure(
        scheduler: (_) async {
          calls++;
          atScheduler = await saved();
          throw StateError('scheduler_unavailable');
        },
      );
      final returned = await _submit(coordinator);
      expect(calls, 1);
      expect(atScheduler, isNotNull);
      _sameIntent(atScheduler!, returned);
      _sameIntent(await saved(), returned);
      expect((await saved()).status, CommandStatus.pending);
      expect(await store.allCommands('account-a'), hasLength(1));
    },
  );

  test('D sync observes durable identity and submit does not wait for server result', () async {
    final transport = _PersistenceProbeTransport(store);
    probe = transport;
    configure(transport: transport);
    final returned = await _submit(coordinator)
        .timeout(const Duration(seconds: 2));
    final atDispatch = await transport.observed.future.timeout(
      const Duration(seconds: 2),
    );
    expect(transport.response.isCompleted, isFalse);
    _sameIntent(atDispatch, returned);
    _sameIntent(await saved(), returned);
    expect(transport.requests, hasLength(1));
    expect((await saved()).status, CommandStatus.dispatching);
  });

  test(
    'E sequential exact submissions preserve one durable identity',
    () async {
      final original = await _submit(coordinator);
      final duplicate = await _submit(coordinator);
      _sameIntent(duplicate, original);
      _sameIntent(await saved(), original);
      expect(await store.allCommands('account-a'), hasLength(1));
    },
  );

  test(
    'F concurrent exact submissions preserve one durable identity',
    () async {
      final results = await Future.wait<CommandEnvelope>([
        _submit(coordinator),
        _submit(coordinator),
      ]);
      _sameIntent(results[0], results[1]);
      _sameIntent(await saved(), results[0]);
      expect(await store.allCommands('account-a'), hasLength(1));
    },
  );

  for (final review in [false, true]) {
    test(
      'G differing unresolved facts reject before scheduler: review=$review',
      () async {
        var calls = 0;
        configure(
          scheduler: (_) async {
            calls++;
            return true;
          },
        );
        final original = await _submit(coordinator);
        if (review) {
          await store.markNeedsReview(
            'account-a',
            original.localId,
            error: 'fixture_review',
            attemptedAt: original.occurredAt,
          );
        }
        final before = await saved();
        final count = calls;
        expect(count, greaterThan(0));
        await expectLater(
          _submit(coordinator, reason: 'سبب مختلف'),
          throwsA(
            isA<SessionCorrectionConflict>().having(
              (e) => e.existing.localId,
              'existing.localId',
              before.localId,
            ),
          ),
        );
        expect(calls, count);
        final after = await saved();
        _sameIntent(after, before);
        expect(after.status, before.status);
        expect(after.lastError, before.lastError);
        expect(await store.allCommands('account-a'), hasLength(1));
      },
    );
  }

  test(
    'H exact review duplicate returns review without another sync opportunity',
    () async {
      var calls = 0;
      configure(
        scheduler: (_) async {
          calls++;
          return true;
        },
      );
      final original = await _submit(coordinator);
      await store.markNeedsReview(
        'account-a',
        original.localId,
        error: 'fixture_review',
        attemptedAt: original.occurredAt,
      );
      final count = calls;
      final duplicate = await _submit(coordinator);
      _sameIntent(duplicate, original);
      expect(duplicate.status, CommandStatus.review);
      expect((await saved()).status, CommandStatus.review);
      expect(calls, count);
      expect(await store.allCommands('account-a'), hasLength(1));
    },
  );

  test(
    'I dispatching duplicate returns existing intent without recreating it',
    () async {
      final original = await _submit(coordinator);
      expect(
        await store.claim(
          'account-a',
          original.localId,
          attemptedAt: original.occurredAt,
        ),
        isTrue,
      );
      final duplicate = await _submit(coordinator);
      _sameIntent(duplicate, original);
      expect(duplicate.status, CommandStatus.dispatching);
      expect(await store.allCommands('account-a'), hasLength(1));
      // قواعد receipt-first يثبتها R6C-4D؛ لا نكررها في هذه الطبقة.
    },
  );
}
