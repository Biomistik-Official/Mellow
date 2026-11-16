import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mellow/l10n.dart';
import 'package:mellow/main.dart';
import 'package:mellow/settings.dart';
import 'package:mellow/workspace.dart';
import 'package:window_manager/legacy.dart';

/// Drives the real app window: editing, autosave, find/replace, tabs, settings.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('core flows work end to end', (t) async {
    final sep = Platform.pathSeparator;
    final dir = Directory.systemTemp.createTempSync('mellow_it_');
    final file = File('${dir.path}${sep}a.txt')..writeAsStringSync('Привет\r\nвторая привет\r\n');
    final settings = AppSettings(Directory('${dir.path}${sep}data'))..language = 'ru';
    final ws = Workspace(dataDir: settings.dir, expiryHours: () => settings.expiryHours);
    await ws.restore();
    await ws.openPath(file.path);
    await windowManager.ensureInitialized();

    // The test window often opens behind other windows, or loses OS focus while the
    // test runs. Windows then reports it as inactive / unfocused, and Flutter moves
    // keyboard focus away from the editor, so shortcuts stop firing. Synthetic key
    // events don't need OS focus, so ignore the real window's lifecycle and focus
    // changes and keep the app resumed for the whole test.
    SystemChannels.lifecycle.setMessageHandler(null);
    t.binding.platformDispatcher.onViewFocusChange = (_) {};
    if (t.binding.lifecycleState != AppLifecycleState.resumed) {
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    await t.pumpWidget(MellowApp(settings: settings, ws: ws));
    await t.pumpAndSettle();
    expect(find.text('a.txt'), findsOneWidget);
    expect(find.text('UTF-8'), findsOneWidget);
    expect(find.text('Windows (CRLF)'), findsOneWidget);

    Future<void> chord(LogicalKeyboardKey key, {bool shift = false}) async {
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(key);
      if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();
    }

    // Typing is saved to the file by itself, keeping CRLF.
    await t.enterText(find.byType(TextField).first, 'Привет\nвторая привет\nновая');
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();
    expect(file.readAsStringSync(), 'Привет\r\nвторая привет\r\nновая');
    expect(find.text(L.t('saved')), findsOneWidget);

    // Find is case-insensitive and counts matches; replace all rewrites them.
    await chord(LogicalKeyboardKey.keyH);
    expect(find.text(L.t('replaceAll')), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, L.t('findHint')), 'ПРИВЕТ');
    await t.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    await t.tap(find.byTooltip(L.t('findNext')));
    await t.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, L.t('replaceHint')), 'мир');
    await t.tap(find.text(L.t('replaceAll')));
    await t.pumpAndSettle();
    expect(ws.current.controller.text, 'мир\nвторая мир\nновая');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.text(L.t('replaceAll')), findsNothing);

    // New tab becomes a draft named after its first line; closing it can be undone.
    await chord(LogicalKeyboardKey.keyN);
    expect(ws.docs.length, 2);
    await t.enterText(find.byType(TextField).first, 'мой черновик\nтекст');
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();
    expect(find.text('мой черновик'), findsOneWidget);
    final draftId = ws.current.id;
    expect(File(ws.draftPath(draftId)).readAsStringSync(), 'мой черновик\nтекст');
    await chord(LogicalKeyboardKey.keyW);
    expect(ws.docs.length, 1);
    expect(find.text(L.t('draftClosed')), findsOneWidget);
    await t.tap(find.text(L.t('undoClose')));
    await t.pumpAndSettle();
    expect(ws.docs.length, 2);
    expect(ws.current.controller.text, 'мой черновик\nтекст');

    // Ctrl+Tab switches tabs.
    await chord(LogicalKeyboardKey.tab);
    expect(ws.current.fileName, 'a.txt');

    // Menus open and run their actions.
    await t.tap(find.text(L.t('view')));
    await t.pumpAndSettle();
    await t.tap(find.text(L.t('wordWrap')));
    await t.pumpAndSettle();
    expect(settings.wordWrap, isFalse);
    await t.tapAt(const Offset(500, 400));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);

    // Settings: dark theme, another colour, English.
    await t.tap(find.byTooltip(L.t('settings')));
    await t.pumpAndSettle();
    expect(find.text(L.t('appearance')), findsOneWidget);
    await t.tap(find.text(L.t('themeDark')));
    await t.pumpAndSettle();
    expect(Theme.of(t.element(find.text(L.t('appearance')))).brightness, Brightness.dark);
    final before = Theme.of(t.element(find.text(L.t('appearance')))).colorScheme.primary;
    await t.tap(find.byWidgetPredicate(
        (w) => w is AnimatedContainer && (w.decoration as BoxDecoration?)?.color == kPalette[9]));
    await t.pumpAndSettle();
    expect(settings.seed, kPalette[9]);
    expect(Theme.of(t.element(find.text(L.t('appearance')))).colorScheme.primary, isNot(before));
    await t.ensureVisible(find.text('English'));
    await t.tap(find.text('English'));
    await t.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    await t.tap(find.byTooltip('Close').last);
    await t.pumpAndSettle();
    expect(find.text('File'), findsOneWidget);
    expect(t.takeException(), isNull);

    // Everything is on disk for the next launch.
    await ws.flushAll();
    final again = Workspace(dataDir: settings.dir, expiryHours: () => 24);
    await again.restore();
    expect(again.docs.map((d) => d.controller.text), ['мир\nвторая мир\nновая', 'мой черновик\nтекст']);
    again.dispose();
  });
}
