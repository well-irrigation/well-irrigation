import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// شاشة البداية المعتمدة وفق وثيقة UX-00
///
/// المواصفات المعتمدة (القرارات 137–140):
/// - خلفية بيضاء باردة بخفة (#F8FAFC).
/// - صورة الختم المحسن في مركز التكوين البصري.
/// - حركة هادئة وبلا أي مدة انتظار مصطنعة.
/// - خالية من أي أزرار أو حقول أو أشرطة تحميل.
class SplashScreen extends StatefulWidget {
  const SplashScreen({
    required this.onInitialized,
    super.key,
  });

  final VoidCallback onInitialized;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeIn,
    );

    _controller.forward();

    // استدعاء اكتمال التهيئة بعد إتاحة رؤية الختم لمدة 2.5 ثانية مريحة
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 2500), () {
        if (mounted) {
          widget.onInitialized();
        }
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Image.asset(
            'assets/images/app_seal.png',
            width: 220,
            height: 220,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              return const Icon(
                Icons.water_drop_outlined,
                size: 80,
                color: AppColors.waterBlue,
              );
            },
          ),
        ),
      ),
    );
  }
}
