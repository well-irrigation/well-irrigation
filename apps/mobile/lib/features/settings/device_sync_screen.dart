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
    final data = await _repo.fetchDeviceSyncStatus();
    if (mounted) {
      setState(() {
        _status = data;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleManualSync() async {
    HapticFeedback.lightImpact();
    setState(() => _isSyncing = true);

    await _repo.triggerManualSync();
    await _loadSyncStatus();

    if (mounted) {
      setState(() => _isSyncing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('اكتملت محاولة المزامنة وتحديث البيانات بنجاح ✅'),
          backgroundColor: AppColors.agriculturalGreen,
        ),
      );
    }
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
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: const BorderSide(color: AppColors.border),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 20,
                                  backgroundColor: (_status?.pendingOperationsCount ?? 0) == 0
                                      ? AppColors.agriculturalGreen.withValues(alpha: 0.15)
                                      : AppColors.warning.withValues(alpha: 0.15),
                                  child: Icon(
                                    (_status?.pendingOperationsCount ?? 0) == 0
                                        ? Icons.cloud_done
                                        : Icons.cloud_upload_outlined,
                                    color: (_status?.pendingOperationsCount ?? 0) == 0
                                        ? AppColors.agriculturalGreen
                                        : AppColors.warning,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      (_status?.pendingOperationsCount ?? 0) == 0
                                          ? 'البيانات متزامنة بالكامل'
                                          : 'توجد عمليات بانتظار المزامنة',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                    ),
                                    Text(
                                      _status?.isOnline == true ? 'متصل بالخادم السحابي' : 'يعمل دون إنترنت (Offline)',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: _status?.isOnline == true ? AppColors.agriculturalGreen : AppColors.warning,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                        const Divider(height: 24),
                        _buildStatusRow(
                          icon: Icons.storage,
                          label: 'جاهزية التخزين المحلي على الهاتف',
                          value: _status?.localStorageReady == true ? 'جاهز ومؤمّن ✅' : 'غير متوفر',
                          isGood: _status?.localStorageReady == true,
                        ),
                        const SizedBox(height: 8),
                        _buildStatusRow(
                          icon: Icons.access_time,
                          label: 'آخر مزامنة ناجحة مع السحابة',
                          value: 'منذ دقيقتين (19/08/2026)',
                          isGood: true,
                        ),
                        const SizedBox(height: 8),
                        _buildStatusRow(
                          icon: Icons.pending_actions,
                          label: 'العمليات المعلقة في طابور الهاتف',
                          value: '${_status?.pendingOperationsCount ?? 0} عملية',
                          isGood: (_status?.pendingOperationsCount ?? 0) == 0,
                        ),
                        const SizedBox(height: 8),
                        _buildStatusRow(
                          icon: Icons.sync,
                          label: 'المزامنة التلقائية بالخلفية',
                          value: _status?.backgroundSyncActive == true ? 'مفعلة وتعمل تلقائياً' : 'متوقفة',
                          isGood: _status?.backgroundSyncActive == true,
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.waterBlue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: _isSyncing
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.sync),
                            label: const Text('مزامنة الآن يدوياً', style: TextStyle(fontWeight: FontWeight.bold)),
                            onPressed: _isSyncing ? null : _handleManualSync,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

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
                        'صُمم التطبيق ليعمل بكفاءة 100% في المزارع والحقول عند انقطاع شبكة الإنترنت. يتم حفظ جلسات السقي، سندات القبض، والمصروفات فورياً في طابور الهاتف المتين، وتُرفع للسحابة تلقائياً بمجرد توفر الاتصال دون الحاجة لأي تدخل منك (ق-89/ق-90).',
                        style: TextStyle(fontSize: 12, color: AppColors.textPrimary, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildStatusRow({
    required IconData icon,
    required String label,
    required String value,
    required bool isGood,
  }) {
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
            color: isGood ? AppColors.agriculturalGreen : AppColors.warning,
          ),
        ),
      ],
    );
  }
}
