import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// مؤشّر انتظار موحَّد: قطرة تسقط في ماء فتتسع منها حلقة.
///
/// **لماذا لا الدوّار التقليدي:** المشغّل يفتح التطبيق عشرات المرات في اليوم
/// عند رأس البئر، فشكل الانتظار جزء من هوية المنتج لا تفصيل. والقطرة تُفهم
/// بلا شرح: شيء يجري وسيصل.
///
/// **ولماذا لا «ماء يرتفع»:** المستوى المرتفع يوحي بمقدار مُنجَز، ولا يعرف
/// هذا المكوّن شيئًا عن التقدّم الحقيقي — فيكون إيحاءً برقم لا يقيسه، وهو
/// من عائلة النجاح الكاذب (ق-113). القطرة تقول «يجري» ولا تدّعي «كم بقي».
///
/// يعمل في الحجم الصغير (داخل زرّ) والكبير (وسط شاشة) بلا صور ولا مكتبات:
/// كل شيء مرسوم بأشكال هندسية.
class WellLoadingIndicator extends StatefulWidget {
  const WellLoadingIndicator({
    super.key,
    this.size = 48,
    this.color = AppColors.waterBlue,
  });

  /// حجم مربّع الرسم. الافتراضي 48 يناسب وسط الشاشة؛ استعمل 18–24 داخل زرّ.
  final double size;

  /// لون القطرة والماء. الافتراضي أزرق الماء من هوية التطبيق.
  final Color color;

  @override
  State<WellLoadingIndicator> createState() => _WellLoadingIndicatorState();
}

class _WellLoadingIndicatorState extends State<WellLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1400),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'جاري التحميل',
      liveRegion: true,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return CustomPaint(
                painter: _DropPainter(
                  progress: _controller.value,
                  color: widget.color,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// نافذة انتظار منبثقة: تُعتِّم ما خلفها وتُظهر الحركة وحدها بلا نصّ.
///
/// **لماذا لا شاشة مستقلة:** الانتقال إلى شاشة كاملة يقطع سياق المستخدم —
/// يختفي ما كان ينظر إليه ثم يعود، فيبدو الانتظار حدثًا لا لحظة. والتعتيم
/// يُبقي الشاشة السابقة مرئية خلفه فيبقى السياق قائمًا.
///
/// **ولماذا بلا نصّ:** «جاري تحميل بيانات حسابك» لا يضيف شيئًا للحركة —
/// الحركة نفسها تقول ذلك. والنصّ يُقرأ في كل انتظار فيصير ضجيجًا.
///
/// **ولماذا بلا بطاقة بيضاء:** أول نسخة وضعت الحركة في بطاقة بيضاء بظلّ،
/// فصارت البطاقة هي ما يُرى والحركة داخلها — والمطلوب عكسه. فحُذفت، وبقي
/// اللون الأبيض للقطرة نفسها لتُقرأ على التعتيم الرمادي.
class WellLoadingOverlay extends StatelessWidget {
  const WellLoadingOverlay({super.key, this.size = 112});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      // تعتيم بلا حجب كامل: ما خلفه يبقى مقروءًا فيبقى السياق.
      color: Colors.black.withValues(alpha: 0.45),
      child: Center(
        // القطرة بيضاء هنا لا زرقاء: الأزرق على تعتيم داكن يخفت، والأبيض
        // يُقرأ على أي خلفية بعد التعتيم.
        child: WellLoadingIndicator(size: size, color: Colors.white),
      ),
    );
  }
}

/// رسّام دورة واحدة: قطرة تنزل، تلمس الماء، ثم تتسع حلقة وتتلاشى.
///
/// **الشكل صُحِّح في 2026-09-04 بعد قياس على جهاز:** النسخة الأولى ظهرت
/// شكلًا مغزليًّا (مُدبَّبًا من الطرفين) لا قطرةً — لأن منحنيين متناظرين
/// حول محور واحد يُنتجان عدسة لا قطرة. القطرة الحقيقية **رأسٌ مُدبَّب وبطنٌ
/// دائرية**: نصفها الأسفل قوس دائري كامل، ونصفها الأعلى ضلعان يلتقيان في
/// نقطة. وحجمها في النسخة الأولى كان 10% من الإطار — نقطةً على شاشة 720
/// عرضًا. الرسم الصغير يُقرأ غبارًا لا شكلًا.
class _DropPainter extends CustomPainter {
  const _DropPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  static const double _fallEnd = 0.58;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // سطح الماء عند 76% من الارتفاع: مجال للسقوط فوقه وللحلقة حوله.
    final surfaceY = h * 0.76;
    final centerX = w / 2;
    final stroke = (w * 0.045).clamp(1.5, 5.0);

    // سطح الماء — خط ثابت يعطي الحركة مرجعًا تُقاس إليه.
    final surfacePaint = Paint()
      ..color = color.withValues(alpha: 0.26)
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(w * 0.16, surfaceY),
      Offset(w * 0.84, surfaceY),
      surfacePaint,
    );

    if (progress < _fallEnd) {
      _paintFallingDrop(canvas, w, h, surfaceY, centerX);
    } else {
      _paintRipple(canvas, w, surfaceY, centerX, stroke);
    }
  }

  /// قطرة بشكلها المعروف: بطن دائرية أسفل ورأس مُدبَّب أعلى.
  ///
  /// البناء: قوس دائري يرسم النصف الأسفل كاملًا، ثم ضلعان بمنحنى تكعيبي
  /// يصعدان من جانبَي الدائرة ويلتقيان في الرأس. وهي تتسارع في نزولها
  /// (تربيع المسافة) كما يفعل الماء، ويطول رأسها مع السرعة.
  void _paintFallingDrop(
    Canvas canvas,
    double w,
    double h,
    double surfaceY,
    double centerX,
  ) {
    final t = progress / _fallEnd;
    final eased = t * t;

    // نصف قطر البطن = 21% من الإطار (كان 10%: نقطة لا شكل).
    final r = w * 0.21;
    final startY = h * 0.20;
    final bellyY = startY + (surfaceY - r * 0.55 - startY) * eased;

    // الرأس يطول مع السرعة: 1.5r واقفة → 2.2r مسرعة.
    final tipY = bellyY - r * (1.5 + eased * 0.7);

    final path = Path()
      // من الجانب الأيسر عند مركز البطن، ثم القوس الدائري للنصف الأسفل.
      ..moveTo(centerX - r, bellyY)
      ..arcToPoint(
        Offset(centerX + r, bellyY),
        radius: Radius.circular(r),
        clockwise: false,
      )
      // الضلع الأيمن يصعد إلى الرأس: نقطتا تحكّم تُبقيانه منتفخًا قرب البطن
      // ثم تشدّانه إلى نقطة حادّة.
      ..cubicTo(
        centerX + r * 0.92,
        bellyY - r * 0.85,
        centerX + r * 0.34,
        tipY + r * 0.52,
        centerX,
        tipY,
      )
      // والضلع الأيسر مرآته.
      ..cubicTo(
        centerX - r * 0.34,
        tipY + r * 0.52,
        centerX - r * 0.92,
        bellyY - r * 0.85,
        centerX - r,
        bellyY,
      )
      ..close();

    canvas.drawPath(path, Paint()..color = color);
  }

  /// الحلقة تتسع وتخفت: البصر يقرأ الاتساع «وصل شيء» لا «انتظر».
  void _paintRipple(
    Canvas canvas,
    double w,
    double surfaceY,
    double centerX,
    double stroke,
  ) {
    final t = (progress - _fallEnd) / (1 - _fallEnd);
    final maxRadius = w * 0.36;

    for (var i = 0; i < 2; i++) {
      // الحلقة الثانية متأخرة قليلًا فتُنتج إحساس الموجة لا الدائرة الواحدة.
      final delayed = (t - i * 0.26).clamp(0.0, 1.0);
      if (delayed <= 0) continue;

      final alpha = (1 - delayed) * (i == 0 ? 0.7 : 0.38);
      if (alpha <= 0.01) continue;

      final radius = maxRadius * delayed;
      final ripplePaint = Paint()
        ..color = color.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * (1 - delayed * 0.4);

      // بيضاوي مفلطح: يقرأه البصر سطحًا أفقيًّا لا كرة.
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(centerX, surfaceY),
          width: radius * 2,
          height: radius * 0.82,
        ),
        ripplePaint,
      );
    }
  }

  @override
  bool shouldRepaint(_DropPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
