import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/app_bootstrap_repository.dart';
import '../../core/api/team_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/digit_utils.dart';

/// شاشة الفريق والصلاحيات (ق-123 / هجرة 094 / م-41E المرحلة 3).
///
/// كانت تقول «إدارة الفريق غير متاحة في هذه النسخة» لأن العقد لم يكن
/// موجودًا. صار موجودًا في هجرة 094، فصارت الشاشة تعرض ما يعيده العقد
/// وحده: أعضاء نافذين، ودعوات بحالتها ووقت انتهائها ومحاولاتها.
///
/// [well] بئر حقيقي من `AppIdentity` — لا معرّف واسم مفردين يُخمَّنان
/// (الثابت 700).
class TeamPermissionsScreen extends StatefulWidget {
  const TeamPermissionsScreen({
    required this.well,
    this.repository,
    super.key,
  });

  final WellSummary well;
  final TeamRepository? repository;

  @override
  State<TeamPermissionsScreen> createState() => _TeamPermissionsScreenState();
}

class _TeamPermissionsScreenState extends State<TeamPermissionsScreen> {
  late TeamRepository _repo;

  WellTeam? _team;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? TeamRepository();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final team = await _repo.fetchWellTeam(widget.well.id);
      if (!mounted) return;
      setState(() {
        _team = team;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _team = null;
        _isLoading = false;
        _error = '$error';
      });
    }
  }

  static String _formatDate(DateTime? value) {
    if (value == null) return '—';
    final local = value.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year}';
  }

  static String _roleLabel(String role) {
    switch (role) {
      case 'owner':
        return 'مالك';
      case 'operator':
        return 'مشغّل';
      case 'partner':
        return 'شريك';
      case 'manager':
        return 'مدير';
      default:
        return role;
    }
  }

  void _showFailure(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.error),
    );
  }

  /// دعوة عضو: اسم ورقم ودور، ثم **خطوة تأكيد تعرض الرقم** ليقرأه المالك
  /// بعينه — خطأ رقم واحد يمنح غريبًا وصولًا إلى بئر فيه نقد (ق-123).
  Future<void> _startInvite() async {
    final draft = await showDialog<_InviteDraft>(
      context: context,
      builder: (_) => const _InviteFormDialog(),
    );
    if (draft == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _InviteConfirmDialog(
        draft: draft,
        wellName: widget.well.name,
      ),
    );
    if (confirmed != true || !mounted) return;

    await _submitInvite(draft);
  }

  Future<void> _submitInvite(_InviteDraft draft) async {
    InviteResult? result;
    Object? failure;

    try {
      result = await _repo.inviteMember(
        wellId: widget.well.id,
        role: draft.role,
        fullName: draft.fullName,
        phone: draft.phone,
      );
    } catch (error) {
      failure = error;
    }

    if (!mounted) return;

    if (failure != null || result == null) {
      _showFailure('تعذر إصدار الدعوة — لم يُضف أحد. تحقق من الاتصال.');
      return;
    }

    await _load();
    if (!mounted) return;

    if (result.isLinked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('للرقم حساب قائم — رُبط بالبئر الآن بلا رمز ✅'),
          backgroundColor: AppColors.agriculturalGreen,
        ),
      );
      return;
    }

    final code = result.code;
    if (code == null || code.isEmpty) {
      _showFailure('صدرت الدعوة بلا رمز — راجع القائمة وأعد الإصدار');
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (_) => _InvitationCodeDialog(
        draft: draft,
        code: code,
        expiresAt: result!.expiresAt,
      ),
    );
  }

  /// إعادة إصدار: نفس الاسم والرقم والدور. الخادم يُبطل السابق ويُصدر
  /// رمزًا جديدًا — فلا رمزان صالحان لشخص واحد.
  Future<void> _reissue(TeamInvitation invitation) async {
    await _submitInvite(
      _InviteDraft(
        fullName: invitation.fullName,
        phone: invitation.phone,
        role: invitation.role,
      ),
    );
  }

  Future<void> _revoke({
    required String role,
    required String phone,
    required String name,
    required String question,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'تأكيد الإلغاء',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),
        content: Text(question, style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('رجوع'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('إلغاء الوصول'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await _repo.revokeMember(
        wellId: widget.well.id,
        role: role,
        phone: phone,
      );
    } catch (_) {
      _showFailure('تعذر الإلغاء — لم يتغيّر شيء. تحقق من الاتصال.');
      return;
    }

    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('أُلغي وصول $name — ولم يُحذف أي سجل'),
        backgroundColor: AppColors.agriculturalGreen,
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
            const Text(
              'الفريق والصلاحيات',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
            ),
            Text(
              widget.well.name,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: _isLoading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: _error != null
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AppColors.waterBlue,
              foregroundColor: Colors.white,
              onPressed: _startInvite,
              icon: const Icon(Icons.person_add_alt),
              label: const Text('إضافة عضو'),
            ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                size: 44,
                color: AppColors.error,
              ),
              const SizedBox(height: 14),
              const Text(
                'تعذر قراءة فريق البئر',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'لم نعرض أعضاء بديلين. تحقق من الاتصال ثم أعد المحاولة.'
                '\n\n$error',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      );
    }

    final team = _team;
    if (team == null) {
      return const SizedBox.shrink();
    }

    final pending = team.invitations.where((i) => i.isPending).toList();
    final closed = team.invitations.where((i) => !i.isPending).toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          _sectionTitle('الأعضاء (${team.members.length})'),
          if (team.members.isEmpty)
            _emptyNote('لا أعضاء بعدك على هذا البئر.')
          else
            ...team.members.map(_memberCard),
          const SizedBox(height: 18),
          _sectionTitle('بانتظار التنشيط (${pending.length})'),
          if (pending.isEmpty)
            _emptyNote('لا دعوات معلَّقة.')
          else
            ...pending.map(_pendingCard),
          if (closed.isNotEmpty) ...[
            const SizedBox(height: 18),
            _sectionTitle('دعوات مُغلقة (${closed.length})'),
            ...closed.map(_closedCard),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.bold,
        color: AppColors.deepBlue,
      ),
    ),
  );

  Widget _emptyNote(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
    ),
  );

  Widget _card({required List<Widget> children}) => Card(
    elevation: 0,
    margin: const EdgeInsets.only(bottom: 10),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: AppColors.border),
    ),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    ),
  );

  Widget _badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
    ),
  );

  Widget _memberCard(TeamMember member) {
    final canRevoke =
        member.isActive && (member.role == 'operator' || member.role == 'partner');

    return _card(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                member.fullName.isEmpty ? 'بلا اسم مسجَّل' : member.fullName,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
            _badge(_roleLabel(member.role), AppColors.waterBlue),
            const SizedBox(width: 6),
            _badge(
              member.isActive ? 'نافذ' : 'مُلغى',
              member.isActive ? AppColors.agriculturalGreen : AppColors.textMuted,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          member.phone.isEmpty ? 'لا رقم في بيانات الحساب' : member.phone,
          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        if (canRevoke) ...[
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: AppColors.error),
              onPressed: () => _revoke(
                role: member.role,
                phone: member.phone,
                name: member.fullName,
                question:
                    'سيتوقف دخول ${member.fullName} إلى ${widget.well.name}. '
                    'ولن يُحذف أي سجل مالي ولا تاريخ عمل.',
              ),
              icon: const Icon(Icons.person_off_outlined, size: 18),
              label: const Text('إلغاء الوصول'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _pendingCard(TeamInvitation invitation) {
    return _card(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                invitation.fullName,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
            _badge(_roleLabel(invitation.role), AppColors.waterBlue),
            const SizedBox(width: 6),
            _badge('بانتظار التنشيط', AppColors.warning),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          invitation.phone,
          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 4),
        Text(
          'تنتهي ${_formatDate(invitation.expiresAt)} · '
          'المحاولات المتبقية ${invitation.attemptsLeft}',
          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              onPressed: () => _reissue(invitation),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('إعادة إصدار الرمز'),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: AppColors.error),
              onPressed: () => _revoke(
                role: invitation.role,
                phone: invitation.phone,
                name: invitation.fullName,
                question:
                    'ستُلغى دعوة ${invitation.fullName} فلا يستطيع تنشيطها '
                    'برمزها. ويمكنك دعوته من جديد في أي وقت.',
              ),
              icon: const Icon(Icons.close, size: 18),
              label: const Text('إلغاء الدعوة'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _closedCard(TeamInvitation invitation) {
    final label = switch (invitation.status) {
      'claimed' => 'نُشِّطت ${_formatDate(invitation.claimedAt)}',
      'expired' => 'انتهت ${_formatDate(invitation.expiresAt)}',
      'revoked' => 'أُلغيت',
      _ => invitation.status,
    };

    return _card(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                invitation.fullName,
                style: const TextStyle(fontSize: 14),
              ),
            ),
            _badge(_roleLabel(invitation.role), AppColors.textMuted),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${invitation.phone} · $label',
          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
      ],
    );
  }
}

/// مسوّدة الدعوة كما جمعتها الشاشة قبل التأكيد.
class _InviteDraft {
  const _InviteDraft({
    required this.fullName,
    required this.phone,
    required this.role,
  });

  final String fullName;
  final String phone;
  final String role;
}

class _InviteFormDialog extends StatefulWidget {
  const _InviteFormDialog();

  @override
  State<_InviteFormDialog> createState() => _InviteFormDialogState();
}

class _InviteFormDialogState extends State<_InviteFormDialog> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  String _role = 'operator';

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    final phone = normalizeArabicDigits(_phoneController.text).trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل اسم العضو')),
      );
      return;
    }

    if (phone.length < 9) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل رقم هاتف من 9 أرقام')),
      );
      return;
    }

    Navigator.of(context).pop(
      _InviteDraft(fullName: name, phone: phone, role: _role),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'إضافة عضو إلى البئر',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'لا تكتب كلمة مرور لأحد: يختارها صاحب الحساب بنفسه بعد أن '
            'يُثبت هويته برمز التنشيط.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'اسم العضو *',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _phoneController,
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
            initialValue: _role,
            decoration: const InputDecoration(
              labelText: 'الدور *',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'operator', child: Text('مشغّل')),
              DropdownMenuItem(value: 'partner', child: Text('شريك')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _role = value);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.waterBlue,
            foregroundColor: Colors.white,
          ),
          onPressed: _submit,
          child: const Text('متابعة'),
        ),
      ],
    );
  }
}

/// خطوة التأكيد: الرقم يُعرض ليقرأه المالك بعينه قبل منح الوصول.
/// خطأ رقم واحد يمنح غريبًا وصولًا إلى بئر فيه نقد (ق-123).
class _InviteConfirmDialog extends StatelessWidget {
  const _InviteConfirmDialog({required this.draft, required this.wellName});

  final _InviteDraft draft;
  final String wellName;

  @override
  Widget build(BuildContext context) {
    final roleLabel = draft.role == 'operator' ? 'تشغيل' : 'اطلاع شريك';

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'تأكيد بيانات العضو',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'سيُمنح ${draft.fullName} صلاحية $roleLabel على $wellName.',
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              draft.phone,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'اقرأ الرقم حرفًا حرفًا: رقم خاطئ يمنح شخصًا آخر وصولًا إلى '
            'بئرك.',
            style: TextStyle(fontSize: 12, color: AppColors.error),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('تعديل'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.agriculturalGreen,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('تأكيد الدعوة'),
        ),
      ],
    );
  }
}

/// الرمز يُعرض **مرة واحدة**: العقد لا يعيده في أي قراءة لاحقة، ولا
/// يُخزَّن نصًّا في القاعدة (الثابت 708).
class _InvitationCodeDialog extends StatelessWidget {
  const _InvitationCodeDialog({
    required this.draft,
    required this.code,
    this.expiresAt,
  });

  final _InviteDraft draft;
  final String code;
  final DateTime? expiresAt;

  @override
  Widget build(BuildContext context) {
    final expiry = expiresAt?.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final expiryText = expiry == null
        ? null
        : '${two(expiry.day)}/${two(expiry.month)}/${expiry.year}';

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'رمز تنشيط العضو',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'اقرأ هذا الرمز على ${draft.fullName} ليُنشِّط حسابه بنفسه.',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.waterBlue.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.waterBlue),
            ),
            child: Text(
              code,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                letterSpacing: 10,
                color: AppColors.deepBlue,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            expiryText == null
                ? 'الرمز يُعرض مرة واحدة — لن يظهر مرة أخرى بعد إغلاق هذه '
                    'النافذة. وإن فُقد فأعد إصداره من القائمة.'
                : 'صالح حتى $expiryText، وخمس محاولات إدخال. والرمز يُعرض '
                    'مرة واحدة — إن فُقد فأعد إصداره من القائمة.',
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          const Text(
            'إرسال الرمز برسالة نصية غير متاح في هذا الإصدار — ولم تُرسل '
            'أي رسالة.',
            style: TextStyle(fontSize: 12, color: AppColors.warning),
          ),
        ],
      ),
      actions: [
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.agriculturalGreen,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('أبلغته شفويًّا'),
        ),
      ],
    );
  }
}
