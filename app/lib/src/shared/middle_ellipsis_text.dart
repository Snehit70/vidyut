import 'package:flutter/material.dart';

/// One line of text that, when it does not fit, drops the middle instead of
/// the end, so a filename keeps its extension: `holiday_phot…2026_final.jpg`.
class MiddleEllipsisText extends StatelessWidget {
  const MiddleEllipsisText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final resolved = DefaultTextStyle.of(context).style.merge(style);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final shown = constraints.maxWidth.isFinite
            ? _fit(text, resolved, constraints.maxWidth, direction, scaler)
            : text;
        return Semantics(
          label: text,
          excludeSemantics: true,
          child: Text(
            shown,
            style: style,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
          ),
        );
      },
    );
  }

  static String _fit(
    String text,
    TextStyle style,
    double maxWidth,
    TextDirection direction,
    TextScaler scaler,
  ) {
    bool fits(String candidate) {
      final painter = TextPainter(
        text: TextSpan(text: candidate, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width <= maxWidth;
    }

    if (fits(text)) return text;
    // Characters kept around the ellipsis, the tail getting the larger half.
    String shorten(int kept) {
      final tail = (kept + 1) ~/ 2 + (kept > 8 ? 2 : 0);
      final head = kept - tail;
      return '${text.substring(0, head < 0 ? 0 : head)}…'
          '${text.substring(text.length - tail)}';
    }

    var low = 1;
    var high = text.length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (fits(shorten(middle))) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return shorten(low);
  }
}
