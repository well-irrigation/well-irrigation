import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/account_repository.dart';
import '../../core/theme/app_colors.dart';

/// شاشة تشخيص الجهاز والمزامنة وقاعدة البيانات المحلية (UX-16A / القرارات 556–570 / ق-89 / ق-90 / ق-114)
class DeviceSyncScreen extends StatefulWidget {
  const DeviceSyncScreen({
    this.repository,
    super.key,
  });

  final AccountRepository? repository;

  @override
  State<DeviceSyncScreen> createState() => _DeviceSyncScreenState();
}

class _DeviceSyncScreenState extends State<DeviceSyncScreen> {
  late AccountRepository _repo;
  bool _isLoading = true;
  bool _isSyncing = false;
  DeviceSyncStatusModel? _status;

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? AccountRepository();
    _loadSyncStatus();
  }

  Future<void> _loadSyncStatus() async {
    setState(() => _isLoading = true);

    try {
      final data = await _repo.fetchDeviceSyncStatus();
      if (!mounted) return;
      setState(() {
        _status = data;
        _isLoading = false;
      });
    } catch (_) {
      // لا حالة مُلفَّقة عند الفشل: تُعرض حالة خطأ صريحة مع إعادة المحاولة.
      if (!mounted) return;
      setState(() {
        _status = null;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleManualSync() async {
    HapticFeedback.lightImpact();
    setState(() => _isSyncing = true);

    String message;
    Color background;
    try {
      await _repo.triggerManualSync();
      message = 'اكتملت المزامنة وتحديث البيانات بنجاح ✅';
      background = AppColors.agriculturalGreen;
    } on ManualSyncUnavailableException {
      // لا يُرسل شيء ولا يُقال إنه أُرسل.
      message = 'المزامنة اليدوية غير متاحة في هذا الإصدار — لم يُرسل شيء';
      background = AppColors.warning;
    } catch (_) {
      message = 'تعذرت المزامنة الآن. عملياتك محفوظة ولم يُفقد شيء.';
      background = AppColors.error;
    }

    await _loadSyncStatus();

    if (!mounted) return;
    setState(() => _isSyncing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: background,
      ),
    );
  }

  String _formatSyncTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.day)}/${two(time.month)}/${time.year} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  /// لا يُترجم «غير مقيس» إلى «متصل»: `null` تبقى `null` في النص المعروض.
  String _connectionLabel(bool? isOnline) {
    if (isOnline == null) return 'حالة الاتصال غير مقيسة في هذا الإصدار';
    return isOnline ? 'متصل بالخادم السحابي' : 'يعمل دون إنترنت (Offline)';
  }

  /// حالة فشل صريحة بدل بطاقة أرقام لم تُقرأ من الجهاز (ق-118).
  Widget _buildLoadFailure() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.error_outline, color: AppColors.error, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'تعذر قراءة حالة الجهاز والمزامنة',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'لا تُعرض هنا أرقام لم تُقرأ من هذا الجهاز. أعد المحاولة لقراءة الحالة الفعلية.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _loadSyncStatus,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('إعادة المحاولة'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('الجهاز والمزامنة', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 1. بطاقة الحالة العامة للمزامنة (القرار 563)
                if (_status == null)
                  _buildLoadFailure()
                else
                  _buildStatusCard(_status!),

                const SizedBox(height: 16),

                // 2. شرح مبدأ Offline-First الميداني (القرار 562–567)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.agriculturalGreen.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.agriculturalGreen.withValues(alpha: 0.2)),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.wifi_off, color: AppColors.agriculturalGreen, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'العمل الميداني دون اتصال (Offline-First)',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.agriculturalGreen),
                          ),
                        ],
                      ),
                      SizedBox(height: 6),
                      Text(
                        'صُمم التطبيق ليعمل في المزارع والحقول عند انقطاع شبكة الإنترنت: تُحفظ جلسات السقي وسندات القبض والمصروفات في طابور الهاتف ثم تُرفع للسحابة (ق-89/ق-90). وما تراه أعلاه هو المقيس فعلًا على هذا الجهاز؛ وما لم يُقس بعد يُكتب «غير مقيس» ولا يُعرض كأنه يعمل.',
                        style: TextStyle(fontSize: 12, color: AppColors.textPrimary, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  /// بطاقة تعرض المقيس فقط: عدد الطابور وتاريخ آخر مزامنة وجاهزية التخزين،
  /// وما لم يُقس يُكتب «غير مقيس» بلون محايد (م-41B3B / ق-120).
  Widget _buildStatusCard(DeviceSyncStatusModel status) {
    final pending = status.pendingOperationsCount;
    final isClear = pending == 0;
    final headerColor = isClear ? AppColors.agriculturalGreen : AppColors.warning;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: headerColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: headerColor.withValues(alpha: 0.12),
                child: Icon(
                  isClear ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
                  color: headerColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isClear
                          ? 'لا توجد عمليات بانتظار المزامنة'
                          : 'بانتظار المزامنة: $pending عملية',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _connectionLabel(status.isOnline),
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 24),
          ..._buildStatusRows(status),
          const SizedBox(height: 14),
          _buildManualSyncButton(),
        ],
      ),
    );
  }

  List<Widget> _buildStatusRows(DeviceSyncStatusModel status) {
    final lastSync = status.lastSyncTime;

    return [
      _buildStatusRow(
        icon: Icons.storage,
        label: 'التخزين المحلي على الهاتف',
        value: status.localStorageReady
            ? 'جاهز على قرص الهاتف ✅'
            : 'غير موصول — الطابور في الذاكرة',
        isGood: status.localStorageReady,
      ),
      const SizedBox(height: 10),
      _buildStatusRow(
        icon: Icons.pending_actions,
        label: 'عمليات معلَّقة في الطابور',
        value: '${status.pendingOperationsCount}',
        isGood: status.pendingOperationsCount == 0,
      ),
      const SizedBox(height: 10),
      _buildStatusRow(
        icon: Icons.history,
        label: 'آخر مزامنة ناجحة',
        value: lastSync == null ? 'لم تنجح مزامنة بعد' : _formatSyncTime(lastSync),
        isGood: lastSync != null,
      ),
      const SizedBox(height: 10),
      _buildStatusRow(
        icon: Icons.sync,
        label: 'المزامنة الخلفية',
        value: status.backgroundSyncActive == null
            ? 'غير مقيسة في هذا الإصدار'
            : (status.backgroundSyncActive! ? 'مفعّلة' : 'متوقفة'),
        isGood: status.backgroundSyncActive,
      ),
    ];
  }

  Widget _buildManualSyncButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _isSyncing ? null : _handleManualSync,
        icon: _isSyncing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.sync, size: 18),
        label: Text(_isSyncing ? 'جارٍ المحاولة…' : 'مزامنة الآن'),
      ),
    );
  }

  /// `isGood == null` تعني «غير مقيس»: لون محايد، فلا يُقرأ كنجاح ولا كخطأ.
  Widget _buildStatusRow({
    required IconData icon,
    required String label,
    required String value,
    required bool? isGood,
  }) {
    final valueColor = isGood == null
        ? AppColors.textSecondary
        : (isGood ? AppColors.agriculturalGreen : AppColors.warning);

    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}
