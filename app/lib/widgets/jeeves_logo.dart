import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Which Jeeves logo mark to show.
///
/// Usage rules (from brand spec):
/// - [pointillist] — primary mark; only at ≥ 32 px. Dots must not be tinted.
/// - [signature]   — backup mark; safe at any size ≥ 16 px; single-colour
///                   contexts, dense UI, favicons. Tittle is always BRAND
///                   #2667B7 and must never be recoloured. Stem is INK on
///                   light surfaces and WHITE on dark — never a third colour.
/// - [wordmark]    — Pointillist mark + "Jeeves" text lockup (Manrope 700).
/// - [auto]        — (default) picks [signature] when [JeevesLogo.size] < 32,
///                   otherwise [pointillist].
enum JeevesLogoVariant { auto, pointillist, signature, wordmark }

/// The Jeeves brand mark.
///
/// ## Usage rules (§Usage from the brand spec)
///
/// ✅ Clear space ≥ 0.5 × mark height on all sides (enforced automatically
///    via internal [Padding] — do not add extra external padding expecting the
///    widget to fill a tight box).
/// ✅ [variant] auto picks **Signature** when [size] < 32, else **Pointillist**.
/// ✅ Signature tittle is always BRAND `#2667B7` — never recoloured.
/// ✅ Signature stem: INK on light, WHITE on dark — [onDark] is inferred from
///    [ThemeData.brightness] unless overridden.
/// ✅ On dark: Pointillist dots appear direct-on-background with per-dot
///    hairline strokes — never on a white plate.
/// ❌ No stretch (non-square container), rotate, outline, drop-shadow, or
///    gradient fills. The widget forces a square bounding box to prevent
///    stretching by construction.
/// ❌ No [ColorFilter] on the Signature stem; use [onDark] to select the
///    correct colour instead.
/// ❌ [size] must be ≥ 16 (minimum legible size even for Signature).
///
/// ## Example
///
/// ```dart
/// // Auto-picks variant, inherits brightness from Theme:
/// JeevesLogo(size: 64)
///
/// // Force Signature on a dark background:
/// JeevesLogo(size: 24, variant: JeevesLogoVariant.signature, onDark: true)
///
/// // App-icon plated variant (for in-app icon previews):
/// JeevesLogo(size: 48, appIcon: true)
/// ```
class JeevesLogo extends StatelessWidget {
  const JeevesLogo({
    super.key,
    this.variant = JeevesLogoVariant.auto,
    required this.size,
    this.onDark,
    this.appIcon = false,
  })  : assert(
          size >= 16,
          'JeevesLogo: size must be ≥ 16 (minimum legible size for Signature). Got $size.',
        ),
        assert(
          !(variant == JeevesLogoVariant.wordmark && appIcon),
          'JeevesLogo: appIcon is not supported with wordmark variant.',
        );

  /// Which mark to display. Defaults to [JeevesLogoVariant.auto].
  final JeevesLogoVariant variant;

  /// The logical size of the mark itself (width = height). The widget's total
  /// footprint is larger because of the mandatory 0.5 × size clear-space
  /// padding applied on every side.
  final double size;

  /// Override the surface brightness. When null the widget infers dark/light
  /// from the ambient [ThemeData.brightness].
  final bool? onDark;

  /// When true, renders the plated app-icon variant (INK rounded-square plate
  /// for Pointillist, BRAND plate for Signature) instead of the transparent
  /// mark. Use for in-app icon previews, About screens, etc.
  final bool appIcon;

  @override
  Widget build(BuildContext context) {
    final isDark = onDark ?? (Theme.of(context).brightness == Brightness.dark);

    final JeevesLogoVariant resolved = switch (variant) {
      JeevesLogoVariant.auto =>
        size < 32 ? JeevesLogoVariant.signature : JeevesLogoVariant.pointillist,
      _ => variant,
    };

    Widget mark;
    if (resolved == JeevesLogoVariant.wordmark) {
      mark = _Wordmark(size: size, isDark: isDark);
    } else {
      mark = SizedBox(
        width: size,
        height: size,
        child: _SvgMark(variant: resolved, isDark: isDark, appIcon: appIcon),
      );
    }

    return Padding(
      padding: EdgeInsets.all(size * 0.5),
      child: mark,
    );
  }
}

/// Loads the correct SVG asset for a non-wordmark variant.
class _SvgMark extends StatelessWidget {
  const _SvgMark({
    required this.variant,
    required this.isDark,
    required this.appIcon,
  });

  final JeevesLogoVariant variant;
  final bool isDark;
  final bool appIcon;

  String get _asset {
    if (appIcon) {
      return switch (variant) {
        JeevesLogoVariant.pointillist => 'assets/brand/logo-pointillist-appicon.svg',
        JeevesLogoVariant.signature   => 'assets/brand/logo-signature-appicon.svg',
        JeevesLogoVariant.auto || JeevesLogoVariant.wordmark =>
          throw StateError('_SvgMark should not receive $variant'),
      };
    }
    return switch (variant) {
      JeevesLogoVariant.pointillist =>
        isDark ? 'assets/brand/logo-pointillist-on-dark.svg'
               : 'assets/brand/logo-pointillist.svg',
      JeevesLogoVariant.signature =>
        isDark ? 'assets/brand/logo-signature-on-dark.svg'
               : 'assets/brand/logo-signature.svg',
      JeevesLogoVariant.auto || JeevesLogoVariant.wordmark =>
        throw StateError('_SvgMark should not receive $variant'),
    };
  }

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      _asset,
      fit: BoxFit.contain,
      // ColorFilter intentionally omitted — the SVG encodes colours directly
      // per brand rules. Do not apply a colorFilter to this widget.
    );
  }
}

/// Pointillist mark + "Jeeves" text in Manrope 700.
class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.size, required this.isDark});

  final double size;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: SvgPicture.asset(
            isDark
                ? 'assets/brand/logo-pointillist-on-dark.svg'
                : 'assets/brand/logo-pointillist.svg',
            fit: BoxFit.contain,
          ),
        ),
        SizedBox(width: size * 0.3),
        Text(
          'Jeeves',
          style: TextStyle(
            fontFamily: 'Manrope',
            fontWeight: FontWeight.w700,
            fontSize: size * 0.75,
            color: isDark ? Colors.white : const Color(0xFF1A1A2E),
            height: 1.0,
          ),
        ),
      ],
    );
  }
}
