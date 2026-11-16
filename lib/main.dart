import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:window_manager/legacy.dart';

import 'instance.dart';
import 'l10n.dart';
import 'settings.dart';
import 'ui/home.dart';
import 'workspace.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final newWindow = args.contains('--new-window');
  final files = [
    for (final a in args)
      if (!a.startsWith('--')) File(a).absolute.path,
  ];

  // One main window: later launches pass their files to it and quit.
  ServerSocket? server;
  if (!newWindow) {
    server = await bindPrimary();
    if (server == null && await sendToPrimary({'open': files})) exit(0);
  }

  final settings = AppSettings(appDataDir())..load();
  final ws = Workspace(
    dataDir: settings.dir,
    expiryHours: () => settings.expiryHours,
    secondary: newWindow,
  );
  await ws.restore();
  for (final f in files) {
    await ws.openPath(f);
  }

  await setUpWindow(settings, restoreBounds: !newWindow);

  if (server != null) {
    servePrimary(server, (msg) async {
      final open = msg['open'];
      if (open is List) {
        for (final p in open) {
          if (p is String) await ws.openPath(p);
        }
        if (await windowManager.isMinimized()) await windowManager.restore();
        await windowManager.show();
        await windowManager.focus();
      }
      final adopt = msg['adopt'];
      if (adopt is List) await ws.adopt(adopt);
    });
  }

  runApp(MellowApp(settings: settings, ws: ws));
}

bool _windowReady = false;

/// Applies size, position and the hidden title bar.
/// Returns false while the native window cannot be reached yet.
Future<bool> _applyWindowOptions(AppSettings settings, bool restoreBounds) async {
  if (_windowReady) return true;
  if (await windowManager.getId() == 0) return false;
  _windowReady = true;
  await windowManager.ensureInitialized();
  final b = restoreBounds ? settings.bounds : null;
  final options = WindowOptions(
    size: b != null ? Size(b[2], b[3]) : const Size(980, 680),
    minimumSize: const Size(520, 360),
    center: b == null,
    title: 'Mellow',
    titleBarStyle: TitleBarStyle.hidden,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    if (b != null) await windowManager.setBounds(Rect.fromLTWH(b[0], b[1], b[2], b[3]));
    if (settings.maximized && restoreBounds) await windowManager.maximize();
    await windowManager.show();
    await windowManager.focus();
  });
  return true;
}

/// Sets the window up, waiting for it when Dart starts before the window is reachable.
///
/// Calling the window API too early does nothing at all, which used to leave the
/// system title bar visible above Mellow's own. So this retries: briefly before
/// the first frame, then in the background until it succeeds.
Future<void> setUpWindow(AppSettings settings, {required bool restoreBounds}) async {
  for (var i = 0; i < 60; i++) {
    if (await _applyWindowOptions(settings, restoreBounds)) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  Timer.periodic(const Duration(milliseconds: 200), (timer) async {
    if (await _applyWindowOptions(settings, restoreBounds)) timer.cancel();
  });
}

class MellowApp extends StatelessWidget {
  const MellowApp({super.key, required this.settings, required this.ws});

  final AppSettings settings;
  final Workspace ws;

  ThemeData _theme(Brightness brightness) {
    final seed = settings.effectiveSeed;
    final grey = HSVColor.fromColor(seed).saturation < 0.08;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: grey ? DynamicSchemeVariant.monochrome : DynamicSchemeVariant.tonalSpot,
    );
    final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: kUiFont,
      fontFamilyFallback: const ['Segoe UI'],
      menuTheme: MenuThemeData(
        style: MenuStyle(
          shape: WidgetStatePropertyAll(rounded),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
        ),
      ),
      menuBarTheme: const MenuBarThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(Colors.transparent),
          shadowColor: WidgetStatePropertyAll(Colors.transparent),
          surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
          elevation: WidgetStatePropertyAll(0),
          padding: WidgetStatePropertyAll(EdgeInsets.zero),
        ),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          minimumSize: const WidgetStatePropertyAll(Size(56, 36)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(shape: rounded, color: scheme.surfaceContainerHigh),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      scrollbarTheme: const ScrollbarThemeData(
        radius: Radius.circular(8),
        thickness: WidgetStatePropertyAll(8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        L.lang = settings.effectiveLanguage;
        return MaterialApp(
          title: 'Mellow',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: settings.themeMode,
          locale: Locale(L.lang),
          supportedLocales: const [Locale('ru'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Home(settings: settings, ws: ws),
        );
      },
    );
  }
}
