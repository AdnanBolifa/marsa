import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// Per-device preferences. Not secret, so they sit beside the vaults as plain
/// JSON rather than inside one.
class AppSettings extends ChangeNotifier {
  AppSettings(this._file);
  final File _file;

  ThemeMode themeMode = ThemeMode.system;

  /// A key of [terminalThemes], or `auto` to follow the app theme.
  String terminalTheme = 'auto';
  double fontSize = 13;

  /// App Store edition: the pass macOS issued for the user's `.ssh` folder,
  /// so the keys in it can be read again after a restart.
  String sshFolder = '';

  /// Local MCP service settings for AI agent credential brokering.
  bool mcpEnabled = false;
  int mcpPort = 47832;

  Future<void> load() async {
    if (!await _file.exists()) return;
    try {
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      themeMode = ThemeMode.values.firstWhere(
        (m) => m.name == j['themeMode'],
        orElse: () => ThemeMode.system,
      );
      terminalTheme = j['terminalTheme'] as String? ?? 'auto';
      fontSize = (j['fontSize'] as num?)?.toDouble() ?? 13;
      sshFolder = j['sshFolder'] as String? ?? '';
      mcpEnabled = j['mcpEnabled'] as bool? ?? false;
      mcpPort = (j['mcpPort'] as num?)?.toInt() ?? 47832;
    } on FormatException {
      // A damaged preferences file just means defaults.
    }
  }

  void update(void Function() change) {
    change();
    notifyListeners();
    _file.writeAsString(
      jsonEncode({
        'themeMode': themeMode.name,
        'terminalTheme': terminalTheme,
        'fontSize': fontSize,
        if (sshFolder.isNotEmpty) 'sshFolder': sshFolder,
        if (mcpEnabled) 'mcpEnabled': mcpEnabled,
        if (mcpPort != 47832) 'mcpPort': mcpPort,
      }),
    );
  }
}

/// Colours that have no slot in [ColorScheme].
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.sidebar,
    required this.muted,
    required this.success,
    required this.warning,
  });
  final Color sidebar;
  final Color muted;
  final Color success;
  final Color warning;

  static Palette of(BuildContext context) =>
      Theme.of(context).extension<Palette>()!;

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(Palette? other, double t) =>
      t < .5 || other == null ? this : other;
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  Color pick(int d, int l) => Color(dark ? d : l);

  final text = pick(0xFFE7EAEF, 0xFF18212B);
  final muted = pick(0xFF8D97A6, 0xFF627084);
  final border = pick(0xFF252B36, 0xFFDFE3E9);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF14B8A6),
        brightness: brightness,
      ).copyWith(
        primary: pick(0xFF2DD4BF, 0xFF0B8A7F),
        onPrimary: pick(0xFF04211E, 0xFFFFFFFF),
        primaryContainer: pick(0xFF113230, 0xFFD9F3EF),
        onPrimaryContainer: pick(0xFF86E8DB, 0xFF0A5C55),
        secondaryContainer: pick(0xFF222935, 0xFFE4E8EE),
        onSecondaryContainer: text,
        surface: pick(0xFF0F1216, 0xFFF5F6F8),
        onSurface: text,
        onSurfaceVariant: muted,
        surfaceContainerLowest: pick(0xFF0A0C0F, 0xFFFFFFFF),
        surfaceContainerLow: pick(0xFF151920, 0xFFFFFFFF),
        surfaceContainer: pick(0xFF1A1F27, 0xFFEEF0F4),
        surfaceContainerHigh: pick(0xFF1F2530, 0xFFE7EAEF),
        surfaceContainerHighest: pick(0xFF283040, 0xFFDCE0E7),
        outline: pick(0xFF5B6575, 0xFF8792A2),
        outlineVariant: border,
        error: pick(0xFFFF7B72, 0xFFC62828),
      );

  TextStyle ts(double size, FontWeight w, [Color? c]) => TextStyle(
    fontSize: size,
    fontWeight: w,
    color: c ?? text,
    letterSpacing: 0,
    height: 1.35,
  );
  final sizes = TextTheme(
    headlineSmall: ts(22, FontWeight.w600),
    titleLarge: ts(18, FontWeight.w600),
    titleMedium: ts(15, FontWeight.w600),
    titleSmall: ts(13, FontWeight.w600),
    bodyLarge: ts(13.5, FontWeight.w400),
    bodyMedium: ts(13, FontWeight.w400),
    bodySmall: ts(12, FontWeight.w400, muted),
    labelLarge: ts(13, FontWeight.w500),
    labelMedium: ts(12, FontWeight.w500),
    labelSmall: ts(11, FontWeight.w500, muted),
  );

  final r8 = BorderRadius.circular(8);
  final shape = RoundedRectangleBorder(borderRadius: r8);
  const pad = EdgeInsets.symmetric(horizontal: 14);
  const min = Size(0, 34);
  OutlineInputBorder inputBorder(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: r8,
    borderSide: BorderSide(color: c, width: w),
  );

  // Resolved once so the styles handed to buttons, dialogs and tooltips carry
  // the platform's font family; a bare TextStyle there would drop it.
  final base = ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    textTheme: sizes,
  );
  final textTheme = base.textTheme;
  TextStyle ui(double size, FontWeight w, Color c) =>
      textTheme.bodyMedium!.copyWith(fontSize: size, fontWeight: w, color: c);

  return base.copyWith(
    extensions: [
      Palette(
        sidebar: pick(0xFF0B0D11, 0xFFECEEF2),
        muted: muted,
        success: pick(0xFF4ADE80, 0xFF16A34A),
        warning: pick(0xFFFBBF24, 0xFFD97706),
      ),
    ],
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
    hoverColor: text.withValues(alpha: .05),
    dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
    iconTheme: IconThemeData(color: muted, size: 18),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(30, 30),
        padding: const EdgeInsets.all(6),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: shape,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: pick(0xFF0F1318, 0xFFFFFFFF),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      hintStyle: ui(13.5, FontWeight.w400, muted.withValues(alpha: .75)),
      border: inputBorder(border),
      enabledBorder: inputBorder(border),
      disabledBorder: inputBorder(border.withValues(alpha: .5)),
      focusedBorder: inputBorder(scheme.primary, 1.5),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: textTheme.titleMedium?.copyWith(fontSize: 16),
      contentTextStyle: textTheme.bodyMedium,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: shape,
        minimumSize: min,
        padding: pad,
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: shape,
        minimumSize: min,
        padding: pad,
        foregroundColor: text,
        side: BorderSide(color: border),
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: shape,
        minimumSize: min,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: textTheme.labelLarge,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: shape,
        side: BorderSide(color: border),
        foregroundColor: muted,
        selectedForegroundColor: text,
        selectedBackgroundColor: scheme.secondaryContainer,
        textStyle: textTheme.labelLarge,
        visualDensity: VisualDensity.compact,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      side: BorderSide(color: scheme.outline, width: 1.4),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      iconColor: muted,
      titleTextStyle: textTheme.bodyMedium?.copyWith(
        fontSize: 13.5,
        fontWeight: FontWeight.w500,
      ),
      subtitleTextStyle: textTheme.bodySmall,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      textStyle: textTheme.bodyMedium,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: border),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      textStyle: ui(12, FontWeight.w400, pick(0xFF0F1216, 0xFFFFFFFF)),
      decoration: BoxDecoration(
        color: pick(0xFFE7EAEF, 0xFF18212B),
        borderRadius: BorderRadius.circular(6),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: 420,
      shape: shape,
    ),
  );
}

TerminalTheme _t(int bg, int fg, int cursor, int selection, List<int> c) =>
    TerminalTheme(
      cursor: Color(cursor),
      selection: Color(selection),
      foreground: Color(fg),
      background: Color(bg),
      black: Color(c[0]),
      red: Color(c[1]),
      green: Color(c[2]),
      yellow: Color(c[3]),
      blue: Color(c[4]),
      magenta: Color(c[5]),
      cyan: Color(c[6]),
      white: Color(c[7]),
      brightBlack: Color(c[8]),
      brightRed: Color(c[9]),
      brightGreen: Color(c[10]),
      brightYellow: Color(c[11]),
      brightBlue: Color(c[12]),
      brightMagenta: Color(c[13]),
      brightCyan: Color(c[14]),
      brightWhite: Color(c[15]),
      searchHitBackground: const Color(0xFFFFE08A),
      searchHitBackgroundCurrent: const Color(0xFFFFB454),
      searchHitForeground: const Color(0xFF000000),
    );

final Map<String, TerminalTheme> terminalThemes = {
  'Marsa Dark': _t(0xFF0C0F14, 0xFFD5DCE5, 0xFF2DD4BF, 0x5514B8A6, const [
    0xFF1B2129, 0xFFF47067, 0xFF57C785, 0xFFE0AF68, //
    0xFF6CB6FF, 0xFFC792EA, 0xFF39C5CF, 0xFFC9D1D9,
    0xFF5C6773, 0xFFFF938A, 0xFF7EE2A8, 0xFFF2CC8F,
    0xFF96D0FF, 0xFFDCBDFB, 0xFF76E3EA, 0xFFFFFFFF,
  ]),
  'Marsa Light': _t(0xFFFFFFFF, 0xFF1F2933, 0xFF0D9488, 0x4414B8A6, const [
    0xFF24292F, 0xFFCF222E, 0xFF116329, 0xFF7D4E00, //
    0xFF0969DA, 0xFF8250DF, 0xFF1B7C83, 0xFF6E7781,
    0xFF57606A, 0xFFA40E26, 0xFF1A7F37, 0xFF633C01,
    0xFF218BFF, 0xFFA475F9, 0xFF3192AA, 0xFF8C959F,
  ]),
  'Dracula': _t(0xFF282A36, 0xFFF8F8F2, 0xFFF8F8F2, 0x6644475A, const [
    0xFF21222C, 0xFFFF5555, 0xFF50FA7B, 0xFFF1FA8C, //
    0xFFBD93F9, 0xFFFF79C6, 0xFF8BE9FD, 0xFFF8F8F2,
    0xFF6272A4, 0xFFFF6E6E, 0xFF69FF94, 0xFFFFFFA5,
    0xFFD6ACFF, 0xFFFF92DF, 0xFFA4FFFF, 0xFFFFFFFF,
  ]),
  'Solarized Dark': _t(0xFF002B36, 0xFF93A1A1, 0xFF93A1A1, 0x66586E75, const [
    0xFF073642, 0xFFDC322F, 0xFF859900, 0xFFB58900, //
    0xFF268BD2, 0xFFD33682, 0xFF2AA198, 0xFFEEE8D5,
    0xFF586E75, 0xFFCB4B16, 0xFF93A1A1, 0xFF839496,
    0xFF6C71C4, 0xFFD33682, 0xFF2AA198, 0xFFFDF6E3,
  ]),
};

TerminalTheme resolveTerminalTheme(String name, Brightness brightness) =>
    terminalThemes[name] ??
    terminalThemes[brightness == Brightness.dark
        ? 'Marsa Dark'
        : 'Marsa Light']!;
