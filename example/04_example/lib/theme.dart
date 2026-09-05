import 'package:flutter/material.dart';

/// Visual identity for one demo scene.
///
/// The two scenes deliberately share no colours, corner radii or type. Each one
/// should read as a different product built by a different team.
@immutable
class Palette {
  const Palette({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.raised,
    required this.border,
    required this.ink,
    required this.inkMuted,
    required this.accent,
    required this.onAccent,
    required this.radius,
    required this.displayFamily,
    required this.displayFallback,
  });

  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color raised;
  final Color border;
  final Color ink;
  final Color inkMuted;
  final Color accent;
  final Color onAccent;
  final double radius;
  final String displayFamily;
  final List<String> displayFallback;

  static const List<String> monoFallback = <String>[
    'Menlo',
    'DejaVu Sans Mono',
    'Courier New',
  ];

  BorderRadius get corner => BorderRadius.circular(radius);

  /// Monospaced style for machine-generated values: timestamps, scores, ids.
  TextStyle mono({
    double size = 12,
    Color? color,
    FontWeight weight = FontWeight.w500,
    double spacing = 0,
  }) => TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: monoFallback,
    fontSize: size,
    height: 1.2,
    color: color ?? ink,
    fontWeight: weight,
    letterSpacing: spacing,
  );

  /// Small upper-case label used for section headers and metadata.
  TextStyle label({Color? color, double size = 11}) => TextStyle(
    fontSize: size,
    height: 1.2,
    letterSpacing: 1.4,
    fontWeight: FontWeight.w600,
    color: color ?? inkMuted,
  );

  /// Display style for the scene title.
  TextStyle display({double size = 30, Color? color}) => TextStyle(
    fontFamily: displayFamily,
    fontFamilyFallback: displayFallback,
    fontSize: size,
    height: 1.05,
    letterSpacing: -0.4,
    fontWeight: FontWeight.w600,
    color: color ?? ink,
  );

  ThemeData get theme {
    final ColorScheme scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          surface: background,
          primary: accent,
          onPrimary: onAccent,
          outline: border,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      splashFactory: NoSplash.splashFactory,
      textTheme: Typography.material2021().black.apply(
        bodyColor: ink,
        displayColor: ink,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: raised,
        hintStyle: TextStyle(color: inkMuted, fontSize: 15),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: corner,
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: corner,
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: corner,
          borderSide: BorderSide(color: accent, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          minimumSize: const Size(0, 50),
          shape: RoundedRectangleBorder(borderRadius: corner),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

/// Control-room palette: dark, dense, monospaced, amber.
const Palette consolePalette = Palette(
  brightness: Brightness.dark,
  background: Color(0xFF0A0E13),
  surface: Color(0xFF121922),
  raised: Color(0xFF18212C),
  border: Color(0xFF23303D),
  ink: Color(0xFFE6EDF3),
  inkMuted: Color(0xFF8296A8),
  accent: Color(0xFFFFB020),
  onAccent: Color(0xFF1A1206),
  radius: 6,
  displayFamily: 'sans-serif',
  displayFallback: <String>['Helvetica Neue', 'Arial'],
);

/// Studio palette: cool light grey, near-black ink, one electric blue.
/// Gallery palette: pale mint ground, deep forest accent, serif display.
const Palette galleryPalette = Palette(
  brightness: Brightness.light,
  background: Color(0xFFEFF4F0),
  surface: Color(0xFFFFFFFF),
  raised: Color(0xFFFFFFFF),
  border: Color(0xFFDCE7DF),
  ink: Color(0xFF0F1A14),
  inkMuted: Color(0xFF5A6B60),
  accent: Color(0xFF0B6E4F),
  onAccent: Color(0xFFFFFFFF),
  radius: 14,
  displayFamily: 'serif',
  displayFallback: <String>['Georgia', 'Times New Roman'],
);

/// Shown when a scene's footage is indexed, in both palettes.
const Color readyGreen = Color(0xFF0E9F6E);
