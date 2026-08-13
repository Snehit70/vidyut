import 'package:flutter/material.dart';

import 'motion.dart';

/// Small dot with a soft expanding halo; pulses while searching.
class PulsingDot extends StatefulWidget {
  const PulsingDot({super.key, this.color, this.size = 10});

  final Color? color;
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
    if (MediaQuery.disableAnimationsOf(context)) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.color ?? Theme.of(context).colorScheme.primary,
            shape: BoxShape.circle,
          ),
        ),
      );
    }
    final effectiveColor =
        widget.color ?? Theme.of(context).colorScheme.primary;
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
                  color: effectiveColor.withValues(alpha: (1 - t) * 0.3),
                ),
              ),
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: effectiveColor,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
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
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
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

/// Short entrance for finite flows such as onboarding. Long lists render
/// immediately and must not use this helper.
class Entrance extends StatelessWidget {
  const Entrance({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
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
