import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api/api_health_repository.dart';
import '../../core/config/app_config.dart';

class BootstrapScreen extends StatefulWidget {
  const BootstrapScreen({required this.config, super.key});

  final AppConfig config;

  @override
  State<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends State<BootstrapScreen> {
  late final SupabaseClient _client;
  late final ApiHealthRepository _repository;

  ApiHealthResult? _result;
  bool _busy = false;

  @override
  void initState() {
    super.initState();

    _client = Supabase.instance.client;
    _repository = ApiHealthRepository(_client);
  }

  Future<void> _probe() async {
    setState(() {
      _busy = true;
      _result = null;
    });

    final result = await _repository.probe();

    if (!mounted) {
      return;
    }

    setState(() {
      _busy = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final authenticated = _client.auth.currentSession != null;

    return Scaffold(
      appBar: AppBar(title: const Text('إدارة البئر والسقي')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Stage 7 • S7-01',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text('تهيئة تطبيق Android وربط حد API المعتمد.'),
            const SizedBox(height: 24),

            const _StatusCard(
              title: 'Flutter',
              value: 'جاهز',
              icon: Icons.phone_android,
            ),

            const SizedBox(height: 12),

            const _StatusCard(
              title: 'Supabase',
              value: 'مهيأ',
              icon: Icons.cloud_done_outlined,
            ),

            const SizedBox(height: 12),

            _StatusCard(
              title: 'المصادقة',
              value: authenticated ? 'توجد جلسة دخول' : 'لا توجد جلسة دخول',
              icon: authenticated
                  ? Icons.verified_user_outlined
                  : Icons.lock_outline,
            ),

            const SizedBox(height: 12),

            const _StatusCard(
              title: 'Data API',
              value: 'schema: api',
              icon: Icons.api_outlined,
            ),

            const SizedBox(height: 24),

            FilledButton.icon(
              onPressed: _busy ? null : _probe,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.health_and_safety_outlined),
              label: const Text('فحص عقد API'),
            ),

            const SizedBox(height: 16),

            if (_result != null) _HealthResultView(result: _result!),

            const SizedBox(height: 28),

            const Text('Supabase URL'),

            SelectableText(
              widget.config.supabaseUrl,
              textDirection: TextDirection.ltr,
            ),

            const SizedBox(height: 28),

            const Text(
              'لا توجد قراءة أو كتابة مباشرة '
              'لجداول الأعمال.',
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.title,
    required this.value,
    required this.icon,
  });

  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(value),
      ),
    );
  }
}

class _HealthResultView extends StatelessWidget {
  const _HealthResultView({required this.result});

  final ApiHealthResult result;

  @override
  Widget build(BuildContext context) {
    final (icon, title, details) = switch (result.status) {
      ApiHealthStatus.authenticationRequired => (
        Icons.lock_outline,
        'المصادقة مطلوبة',
        'api.health محمي ولا يعمل كـ anon.',
      ),

      ApiHealthStatus.healthy => (
        Icons.check_circle_outline,
        'عقد API يعمل',
        result.payload.toString(),
      ),

      ApiHealthStatus.failed => (
        Icons.error_outline,
        'تعذر فحص API',
        result.message ?? 'خطأ غير معروف',
      ),
    };

    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(details, textDirection: TextDirection.ltr),
      ),
    );
  }
}
