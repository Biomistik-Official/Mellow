import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

/// Seed colours offered in the palette: every Material primary plus neutral grey.
const List<Color> kPalette = [
  Color(0xFFF44336), // red
  Color(0xFFE91E63), // pink
  Color(0xFF9C27B0), // purple
  Color(0xFF673AB7), // deep purple
  Color(0xFF3F51B5), // indigo
  Color(0xFF2196F3), // blue
  Color(0xFF03A9F4), // light blue
  Color(0xFF00BCD4), // cyan
  Color(0xFF009688), // teal
  Color(0xFF4CAF50), // green
  Color(0xFF8BC34A), // light green
  Color(0xFFCDDC39), // lime
  Color(0xFFFFEB3B), // yellow
  Color(0xFFFFC107), // amber
  Color(0xFFFF9800), // orange
  Color(0xFFFF5722), // deep orange
  Color(0xFF795548), // brown
  Color(0xFF607D8B), // blue grey
  Color(0xFF9E9E9E), // grey
];

/// Bundled interface font (assets/fonts, SIL Open Font License).
const String kUiFont = 'Google Sans Flex';

const List<String> kFonts = [
  kUiFont,
  'Consolas',
  'Cascadia Mono',
  'Cascadia Code',
  'Courier New',
  'Lucida Console',
  'Segoe UI',
  'Calibri',
  'Arial',
  'Verdana',
  'Tahoma',
  'Georgia',
  'Times New Roman',
];

/// Folder for settings, session and drafts.
Directory appDataDir() {
  final override = Platform.environment['MELLOW_DATA_DIR'];
  if (override != null && override.isNotEmpty) return Directory(override);
  final base = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
  return Directory('$base${Platform.pathSeparator}Mellow');
}

/// Reads the Windows accent colour, or null when it is unavailable.
Color? readWindowsAccent() {
  if (!Platform.isWindows) return null;
  try {
    final r = Process.runSync('reg', ['query', r'HKCU\Software\Microsoft\Windows\DWM', '/v', 'AccentColor']);
    final m = RegExp(r'AccentColor\s+REG_DWORD\s+0x([0-9a-fA-F]+)').firstMatch('${r.stdout}');
    if (m == null) return null;
    final v = int.parse(m.group(1)!, radix: 16); // stored as ABGR
    return Color.fromARGB(0xFF, v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF);
  } catch (_) {
    return null;
  }
}

class AppSettings extends ChangeNotifier {
  AppSettings(this.dir);

  final Directory dir;

  ThemeMode themeMode = ThemeMode.system;
  bool useAccent = false;
  Color seed = const Color(0xFF673AB7);
  String language = 'system'; // system | ru | en
  String fontFamily = 'Consolas';
  double fontSize = 15;
  bool wordWrap = true;
  bool showStatusBar = true;
  int expiryHours = 24;
  List<double>? bounds; // x, y, w, h
  bool maximized = false;

  Color? _accent;
  Timer? _timer;

  File get _file => File('${dir.path}${Platform.pathSeparator}settings.json');

  String get effectiveLanguage {
    if (language == 'ru' || language == 'en') return language;
    return Platform.localeName.toLowerCase().startsWith('ru') ? 'ru' : 'en';
  }

  Color get effectiveSeed => useAccent ? (_accent ??= readWindowsAccent() ?? seed) : seed;

  void load() {
    try {
      final j = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      themeMode = ThemeMode.values.asNameMap()[j['theme']] ?? themeMode;
      useAccent = j['useAccent'] as bool? ?? useAccent;
      seed = Color((j['seed'] as num?)?.toInt() ?? seed.toARGB32());
      language = j['language'] as String? ?? language;
      fontFamily = j['font'] as String? ?? fontFamily;
      fontSize = ((j['fontSize'] as num?)?.toDouble() ?? fontSize).clamp(8, 48);
      wordWrap = j['wordWrap'] as bool? ?? wordWrap;
      showStatusBar = j['statusBar'] as bool? ?? showStatusBar;
      expiryHours = (j['expiryHours'] as num?)?.toInt() ?? expiryHours;
      final b = j['bounds'];
      if (b is List && b.length == 4) bounds = [for (final v in b) (v as num).toDouble()];
      maximized = j['maximized'] as bool? ?? false;
    } catch (_) {
      // First launch or unreadable file: keep defaults.
    }
  }

  /// Applies [change], repaints the app and saves shortly after.
  void update(void Function() change) {
    change();
    if (useAccent) _accent = null;
    notifyListeners();
    saveSoon();
  }

  void saveSoon() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), saveNow);
  }

  void saveNow() {
    _timer?.cancel();
    try {
      dir.createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode({
        'theme': themeMode.name,
        'useAccent': useAccent,
        'seed': seed.toARGB32(),
        'language': language,
        'font': fontFamily,
        'fontSize': fontSize,
        'wordWrap': wordWrap,
        'statusBar': showStatusBar,
        'expiryHours': expiryHours,
        'bounds': bounds,
        'maximized': maximized,
      }));
    } catch (_) {}
  }
}
