import 'package:flutter/material.dart';

/// Vidyut's semantic palette: raspberry action color, warm tonal surfaces,
/// and plum text in light and dark schemes.
abstract final class Palette {
  static const ground = Color(0xFFFFFFFF);
  static const mist = Color(0xFFFDF0F4);
  static const petal = Color(0xFFF8D3DE);
  static const raspberry = Color(0xFFD9486E);
  static const ink = Color(0xFF33202B);
  static const muted = Color(0xFFA88794);
  static const hairline = Color(0xFFF4DBE4);
  static const error = Color(0xFFB3283E);
  static const active = Color(0xFFA85B00);
  static const activeMist = Color(0xFFFFF7ED);
  static const success = Color(0xFF2D8A4A);
  static const successMist = Color(0xFFEDF8F0);
  static const warning = Color(0xFFA05A00);
  static const warningMist = Color(0xFFFFF7E8);

  static const darkGround = Color(0xFF171116);
  static const darkMist = Color(0xFF241A20);
  static const darkPetal = Color(0xFF8F2949);
  static const darkRaspberry = Color(0xFFFFB1C3);
  static const darkInk = Color(0xFFF8EAF0);
  static const darkMuted = Color(0xFFD4B8C4);
  static const darkHairline = Color(0xFF5A3B48);
  static const darkError = Color(0xFFFFB3BD);
  static const darkSuccess = Color(0xFF8DDB9F);
  static const darkWarning = Color(0xFFFFB870);
}

@immutable
class VidyutStatusColors extends ThemeExtension<VidyutStatusColors> {
  const VidyutStatusColors({
    required this.success,
    required this.successContainer,
    required this.warning,
    required this.warningContainer,
    required this.active,
    required this.activeContainer,
  });

  final Color success;
  final Color successContainer;
  final Color warning;
  final Color warningContainer;
  final Color active;
  final Color activeContainer;

  static VidyutStatusColors of(BuildContext context) {
    return Theme.of(context).extension<VidyutStatusColors>()!;
  }

  @override
  VidyutStatusColors copyWith({
    Color? success,
    Color? successContainer,
    Color? warning,
    Color? warningContainer,
    Color? active,
    Color? activeContainer,
  }) {
    return VidyutStatusColors(
      success: success ?? this.success,
      successContainer: successContainer ?? this.successContainer,
      warning: warning ?? this.warning,
      warningContainer: warningContainer ?? this.warningContainer,
      active: active ?? this.active,
      activeContainer: activeContainer ?? this.activeContainer,
    );
  }

  @override
  VidyutStatusColors lerp(
    covariant ThemeExtension<VidyutStatusColors>? other,
    double t,
  ) {
    if (other is! VidyutStatusColors) return this;
    return VidyutStatusColors(
      success: Color.lerp(success, other.success, t)!,
      successContainer: Color.lerp(
        successContainer,
        other.successContainer,
        t,
      )!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningContainer: Color.lerp(
        warningContainer,
        other.warningContainer,
        t,
      )!,
      active: Color.lerp(active, other.active, t)!,
      activeContainer: Color.lerp(activeContainer, other.activeContainer, t)!,
    );
  }
}
