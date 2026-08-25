import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/account_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/digit_utils.dart';

/// شاشة إدارة الفريق والصلاحيات داخل البئر (UX-16A / القرارات 546–555 / ق-84 / ق-101)
class TeamPermissionsScreen extends StatefulWidget {
  const TeamPermissionsScreen({
    required this.wellId,
    required this.wellName,
    this.repository,
    super.key,
  });

  final String wellId;
  final String wellName;
  final AccountRepository? repository;

  @override
  State<TeamPermissionsScreen> createState() => _TeamPermissionsScreenState();
}

class _TeamPermissionsScreenState extends State<TeamPermissionsScreen> {
  late AccountRepository _repo;
  bool _isLoading = true;
  List<TeamMemberItem> _team = [];

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? AccountRepository();
    _loadTeam();
  }

  Future<void> _loadTeam() async {
    setState(() => _isLoading = true);
    final list = await _repo.fetchWellTeam(widget.wellId);
    if (mounted) {
      setState(() {
        _team = list;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleToggleStatus(TeamMemberItem member) async {
    HapticFeedback.lightImpact();

    // فحص حماية المالك الوحيد (القرار 553)
    if (member.role == 'owner') {
      final ownersCount = _team.where((m) => m.role == 'owner' && m.status == 'active').length;
      if (ownersCount <= 1 && member.status == 'active') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('لا يمكن تعطيل المالك الوحيد للبئر؛ يجب وجود مالك مسؤول دائماً (القرار 553).'),
            backgroundColor: AppColors.error,
          ),
        );
        return;
      }
    }

    // فحص حماية المشغل أثناء جلسة أو مناوبة جارية (القرار 550)
    if (member.role == 'operator' && member.status == 'active' && member.hasActiveShiftOrSession) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لا يمكن تعطيل هذا المشغل لوجود جلسة سقي أو مناوبة جارية مرتبطة به (القرار 550).'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    final newStatus = member.status == 'active' ? 'inactive' : 'active';
    await _repo.toggleTeamMemberStatus(assignmentId: member.assignmentId, newStatus: newStatus);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(newStatus == 'active' ? 'تم تفعيل تعيين العضو بنجاح ✅' : 'تم تعطيل تعيين العضو مؤقتاً ⏸️'),
          backgroundColor: newStatus == 'active' ? AppColors.agriculturalGreen : AppColors.textSecondary,
        ),
      );
      _loadTeam();
    }
  }

  void _showAddMemberDialog() {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    String selectedRole = 'operator';
    bool isSubmitting = false;

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('إضافة عضو جديد للفريق', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'سيتم ربط الشخص بالبئر برقم هاتفه المعتمد دون تكرار الهوية (ق-84).',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'الاسم الكامل *',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    ArabicToEnglishDigitsFormatter(),
                    LengthLimitingTextInputFormatter(9),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'رقم الهاتف (7xxxxxxxx) *',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.phone_android),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedRole,
                  decoration: const InputDecoration(
                    labelText: 'الدور التشغيلي بالبئر *',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'operator', child: Text('مشغل ميداني (تسجيل السقي والقبض)')),
                    DropdownMenuItem(value: 'accountant', child: Text('محاسب (تسجيل المصروفات والتقارير)')),
                    DropdownMenuItem(value: 'viewer', child: Text('مستعرض (مشاهدة السجلات فقط)')),
                  ],
                  onChanged: (val) => setDialogState(() => selectedRole = val ?? 'operator'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.agriculturalGreen,
                foregroundColor: Colors.white,
              ),
              onPressed: isSubmitting
                  ? null
                  : () async {
                      final name = nameController.text.trim();
                      final phone = normalizeArabicDigits(phoneController.text).trim();

                      if (name.isEmpty || phone.length < 9) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('يرجى ملء الاسم ورقم هاتف صحيح من 9 أرقام')),
                        );
                        return;
                      }

                      setDialogState(() => isSubmitting = true);
                      final messenger = ScaffoldMessenger.of(context);
                      final navigator = Navigator.of(dialogCtx);
                      await _repo.addTeamMember(
                        wellId: widget.wellId,
                        fullName: name,
                        phone: phone,
                        role: selectedRole,
                      );

                      if (mounted) {
                        navigator.pop();
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('تمت إضافة عضو الفريق بنجاح ✅'),
                            backgroundColor: AppColors.agriculturalGreen,
                          ),
                        );
                        _loadTeam();
                      }
                    },
              child: isSubmitting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('إضافة وتعيين'),
            ),
          ],
        ),
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('الفريق والصلاحيات', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
            Text(widget.wellName, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.agriculturalGreen,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add),
        label: const Text('إضافة عضو للفريق', style: TextStyle(fontWeight: FontWeight.bold)),
        onPressed: _showAddMemberDialog,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // إشعار الأمان والضوابط (القرارات 546–551)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.waterBlue.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.waterBlue.withValues(alpha: 0.2)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.shield_outlined, color: AppColors.waterBlue, size: 22),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'تخص هذه القائمة إدارة العاملين في هذا البئر فقط. تعطيل المشغل أو الشريك لا يمحو سجلاته التاريخية إطلاقاً (ق-101).',
                          style: TextStyle(fontSize: 12, color: AppColors.waterBlue, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                Text(
                  'أعضاء الفريق المسجلون (${_team.length})',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const SizedBox(height: 8),

                ..._team.map((member) {
                  final isActive = member.status == 'active';
                  return Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(bottom: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: isActive ? AppColors.border : AppColors.border.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: member.role == 'owner'
                                ? AppColors.waterBlue.withValues(alpha: 0.15)
                                : AppColors.agriculturalGreen.withValues(alpha: 0.15),
                            child: Icon(
                              member.role == 'owner' ? Icons.star : Icons.person,
                              color: member.role == 'owner' ? AppColors.waterBlue : AppColors.agriculturalGreen,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      member.fullName,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                        color: isActive ? null : AppColors.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppColors.background,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(color: AppColors.border),
                                      ),
                                      child: Text(
                                        member.roleArabic,
                                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    const Icon(Icons.phone_android, size: 13, color: AppColors.textSecondary),
                                    const SizedBox(width: 4),
                                    Text(
                                      member.phone,
                                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      isActive ? '• نشط' : '• موقوف',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isActive ? AppColors.agriculturalGreen : AppColors.error,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (member.role != 'owner')
                            IconButton(
                              icon: Icon(
                                isActive ? Icons.pause_circle_outline : Icons.play_circle_outline,
                                color: isActive ? AppColors.warning : AppColors.agriculturalGreen,
                              ),
                              tooltip: isActive ? 'تعطيل التعيين مؤقتاً' : 'إعادة التفعيل',
                              onPressed: () => _handleToggleStatus(member),
                            ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 60),
              ],
            ),
    );
  }
}
