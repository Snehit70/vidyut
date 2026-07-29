import 'package:flutter/material.dart';

import 'motion.dart';
import 'palette.dart';

/// Organic blob that slowly morphs between two silhouettes (9-12s loop).
class MorphingBlob extends StatefulWidget {
  const MorphingBlob({
    super.key,
    required this.size,
    this.color = Palette.raspberry,
    this.child,
  });

  final double size;
  final Color color;
  final Widget? child;

  @override
  State<MorphingBlob> createState() => _MorphingBlobState();
}

class _MorphingBlobState extends State<MorphingBlob>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 10),
  );

  @override
  void initState() {
    super.initState();
    if (Motion.loopsEnabled) _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  BorderRadius _silhouette(double t) {
    final s = widget.size;
    Radius r(double x, double y) => Radius.elliptical(s * x, s * y);
    Radius lerp(Radius a, Radius b) => Radius.lerp(a, b, t)!;
    return BorderRadius.only(
      topLeft: lerp(r(.42, .55), r(.55, .48)),
      topRight: lerp(r(.58, .45), r(.45, .52)),
      bottomRight: lerp(r(.63, .58), r(.52, .46)),
      bottomLeft: lerp(r(.37, .42), r(.48, .54)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.color,
            borderRadius: _silhouette(t),
          ),
          child: child,
        );
      },
      child: widget.child == null ? null : Center(child: widget.child),
    );
  }
}

/// Small dot with a soft expanding halo; pulses while searching.
class PulsingDot extends StatefulWidget {
  const PulsingDot({super.key, this.color = Palette.raspberry, this.size = 10});

  final Color color;
  final double size;

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (Motion.loopsEnabled) _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final halo = widget.size * 2.6;
    return SizedBox(
      width: halo,
      height: halo,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = Curves.easeOut.transform(_controller.value);
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: widget.size + (halo - widget.size) * t,
                height: widget.size + (halo - widget.size) * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: (1 - t) * 0.3),
                ),
              ),
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Ripple rings radiating outward from a central child (success orb).
class RippleRings extends StatefulWidget {
  const RippleRings({
    super.key,
    required this.size,
    this.color = Palette.petal,
    this.child,
  });

  final double size;
  final Color color;
  final Widget? child;

  @override
  State<RippleRings> createState() => _RippleRingsState();
}

class _RippleRingsState extends State<RippleRings>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  @override
  void initState() {
    super.initState();
    if (Motion.loopsEnabled) _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) => CustomPaint(
          painter: _RingsPainter(
            progress: _controller.value,
            color: widget.color,
          ),
          child: child,
        ),
        child: widget.child == null ? null : Center(child: widget.child),
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (var i = 0; i < 3; i++) {
      final t = (progress + i / 3) % 1;
      paint.color = color.withValues(alpha: (1 - t) * 0.8);
      canvas.drawCircle(center, maxRadius * (0.45 + 0.55 * t), paint);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

/// Squash-on-press wrapper: 0.93 down, spring overshoot back up (~300ms).
class PressableScale extends StatefulWidget {
  const PressableScale({super.key, required this.child});

  final Widget child;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1,
        duration: _pressed ? Motion.pressDown : Motion.pressUp,
        curve: _pressed ? Curves.easeOutCubic : Motion.spring,
        child: widget.child,
      ),
    );
  }
}

/// Staggered screen entrance: rise 30px + fade, 600ms, 100ms apart.
class Entrance extends StatelessWidget {
  const Entrance({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final delay = Motion.stagger * index;
    final total = Motion.entrance + delay;
    final start = delay.inMilliseconds / total.inMilliseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      builder: (context, raw, child) {
        final t = Interval(start, 1).transform(raw);
        final rise = 30 * (1 - Motion.spring.transform(t));
        return Opacity(
          opacity: Curves.easeOutCubic.transform(t).clamp(0.0, 1.0),
          child: Transform.translate(offset: Offset(0, rise), child: child),
        );
      },
      child: child,
    );
  }
}

extension EntranceMotion on Widget {
  Widget entrance(int index) => Entrance(index: index, child: this);
}
