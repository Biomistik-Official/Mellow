import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/legacy.dart';

import '../encoding.dart';
import '../instance.dart';
import '../l10n.dart';
import '../settings.dart';
import '../updater.dart';
import '../workspace.dart';
import 'editor.dart';
import 'settings_dialog.dart';

class Home extends StatefulWidget {
  const Home({super.key, required this.settings, required this.ws, this.updater});

  final AppSettings settings;
  final Workspace ws;
  final Updater? updater;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WindowListener {
  final _editorKey = GlobalKey();
  final _findCtl = TextEditingController();
  final _replCtl = TextEditingController();
  final _findFocus = FocusNode();

  bool _findOpen = false;
  bool _replaceOpen = false;
  bool _matchCase = false;
  bool _ctrl = false;
  bool _maximized = false;
  bool _alwaysOnTop = false;
  bool _closing = false;
  double _zoom = 1;
  Doc? _lastDoc;

  Workspace get ws => widget.ws;
  AppSettings get settings => widget.settings;
  Doc get doc => ws.current;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
    ws.addListener(_onWorkspace);
    widget.updater?.addListener(_onUpdateReady);
    ws.onError = _showError;
    ws.onTextChanged = (d) {
      if (_findOpen && d == doc) Future.microtask(() => _recompute(jump: false));
    };
    HardwareKeyboard.instance.addHandler(_onKey);
    _lastDoc = doc;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      doc.focus.requestFocus();
      _updateTitle();
      _onUpdateReady();
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    HardwareKeyboard.instance.removeHandler(_onKey);
    ws.removeListener(_onWorkspace);
    widget.updater?.removeListener(_onUpdateReady);
    _findCtl.dispose();
    _replCtl.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent e) {
    final c = HardwareKeyboard.instance.isControlPressed;
    if (c != _ctrl && mounted) setState(() => _ctrl = c);
    // Text fields swallow Escape, so the find bar is closed from here.
    if (e is KeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.escape &&
        _findOpen &&
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? true)) {
      _closeFind();
      return true;
    }
    return false;
  }

  void _onWorkspace() {
    if (!mounted) return;
    if (!identical(_lastDoc, doc)) {
      final old = _lastDoc;
      if (old != null && ws.docs.contains(old)) old.controller.setMatches(const [], -1);
      _lastDoc = doc;
      _updateTitle();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_findOpen) {
          _recompute(jump: false);
        } else {
          doc.focus.requestFocus();
        }
      });
    }
    setState(() {});
  }

  String _titleOf(Doc d) => d.fileName ?? d.firstLine ?? L.t('untitled');

  void _updateTitle() => windowManager.setTitle('${_titleOf(doc)} — Mellow');

  void _showError(String key, String detail) {
    if (!mounted) return;
    final name = detail.substring(detail.lastIndexOf(Platform.pathSeparator) + 1);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${L.t(key)}: $name'), width: 420),
    );
  }

  String? _announcedUpdate;

  /// A newer release is downloaded: offer a restart. Closing Mellow installs it too.
  void _onUpdateReady() {
    final v = widget.updater?.readyVersion;
    if (!mounted || v == null || v == _announcedUpdate) return;
    _announcedUpdate = v;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${L.t('updateReady')} $v'),
      width: 460,
      duration: const Duration(hours: 1),
      showCloseIcon: true,
      action: SnackBarAction(label: L.t('restart'), onPressed: _restartForUpdate),
    ));
  }

  Future<void> _restartForUpdate() async {
    if (await widget.updater?.launchInstaller(relaunch: true) ?? false) {
      await windowManager.close();
    }
  }

  // ---- window ----------------------------------------------------------

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    await ws.flushAll();
    if (ws.secondary) {
      final tabs = ws.exportTabs();
      if (tabs.isNotEmpty && !await sendToPrimary({'adopt': tabs})) {
        await ws.appendToSessionFile();
      }
    } else {
      settings.saveNow();
      // No-op when the restart button already started the installer.
      await widget.updater?.launchInstaller(relaunch: false);
    }
    await windowManager.destroy();
  }

  @override
  void onWindowMaximize() {
    setState(() => _maximized = true);
    if (!ws.secondary) settings.update(() => settings.maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    setState(() => _maximized = false);
    if (!ws.secondary) settings.update(() => settings.maximized = false);
  }

  @override
  void onWindowResized() => _rememberBounds();

  @override
  void onWindowMoved() => _rememberBounds();

  Future<void> _rememberBounds() async {
    if (ws.secondary || _maximized) return;
    final r = await windowManager.getBounds();
    settings.bounds = [r.left, r.top, r.width, r.height];
    settings.saveSoon();
  }

  // ---- file actions ----------------------------------------------------

  static const _textExt = ['txt', 'log', 'ini', 'md', 'cfg', 'conf', 'json', 'xml', 'csv', 'yaml', 'yml'];

  Future<void> _open() async {
    final picked = await openFiles(acceptedTypeGroups: [
      XTypeGroup(label: L.t('allFiles')),
      XTypeGroup(label: L.t('textFiles'), extensions: _textExt),
    ]);
    for (final f in picked) {
      await ws.openPath(f.path);
    }
  }

  Future<void> _save() async {
    if (doc.path == null) return _saveAs();
    await ws.save(doc);
  }

  Future<void> _saveAs() async {
    final d = doc;
    final base = (d.fileName ?? '${d.firstLine ?? L.t('untitled')}.txt')
        .replaceAll(RegExp(r'[\\/:*?"<>|…]'), '')
        .trim();
    final loc = await getSaveLocation(
      suggestedName: base.isEmpty ? 'note.txt' : base,
      acceptedTypeGroups: [
        XTypeGroup(label: L.t('textFiles'), extensions: const ['txt']),
        XTypeGroup(label: L.t('allFiles')),
      ],
    );
    if (loc == null) return;
    var path = loc.path;
    final name = path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);
    if (!name.contains('.')) path = '$path.txt';
    await ws.saveAs(d, path);
    _updateTitle();
  }

  void _newWindow() {
    Process.start(Platform.resolvedExecutable, ['--new-window'], mode: ProcessStartMode.detached);
  }

  Future<void> _close(int i) async {
    final d = ws.docs[i];
    final hadDraft = d.isUntitled && d.controller.text.isNotEmpty;
    final closed = await ws.closeAt(i);
    void finalize() => Future.delayed(const Duration(milliseconds: 400), () => ws.finalizeClose(closed));
    if (!hadDraft || !mounted) return finalize();
    final m = ScaffoldMessenger.of(context)..clearSnackBars();
    final bar = m.showSnackBar(SnackBar(
      width: 380,
      duration: const Duration(seconds: 6),
      content: Text(L.t('draftClosed')),
      action: SnackBarAction(label: L.t('undoClose'), onPressed: () => ws.reopen(closed, i)),
    ));
    bar.closed.then((_) => finalize());
  }

  // ---- edit actions ----------------------------------------------------

  TextSelection get _sel {
    final c = doc.controller;
    final s = c.selection;
    return s.isValid ? s : TextSelection.collapsed(offset: c.text.length);
  }

  void _replaceSelection(String insert) {
    final c = doc.controller;
    final s = _sel;
    c.value = TextEditingValue(
      text: c.text.replaceRange(s.start, s.end, insert),
      selection: TextSelection.collapsed(offset: s.start + insert.length),
    );
    doc.focus.requestFocus();
    _reveal(s.start + insert.length);
  }

  Future<void> _copy({bool cut = false}) async {
    final s = _sel;
    if (s.isCollapsed) return;
    await Clipboard.setData(ClipboardData(text: s.textInside(doc.controller.text)));
    if (cut) _replaceSelection('');
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text;
    if (t == null || t.isEmpty) return;
    _replaceSelection(t.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));
  }

  void _delete() {
    if (!_sel.isCollapsed) _replaceSelection('');
  }

  void _selectAll() {
    final c = doc.controller;
    c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
    doc.focus.requestFocus();
  }

  void _timeDate() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    _replaceSelection('${p(n.hour)}:${p(n.minute)} ${p(n.day)}.${p(n.month)}.${n.year}');
  }

  void _setZoom(double z) => setState(() => _zoom = z.clamp(0.5, 5.0));

  /// Scrolls the editor so that [offset] is visible.
  void _reveal(int offset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _editorKey.currentContext;
      if (ctx == null) return;
      EditableTextState? st;
      void visit(Element e) {
        if (st != null) return;
        if (e is StatefulElement && e.state is EditableTextState) {
          st = e.state as EditableTextState;
          return;
        }
        e.visitChildren(visit);
      }

      (ctx as Element).visitChildren(visit);
      st?.bringIntoView(TextPosition(offset: offset.clamp(0, doc.controller.text.length)));
    });
  }

  Future<void> _goTo() async {
    final ctl = TextEditingController();
    final line = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('goTo').replaceAll('…', '')),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: L.t('lineNumber'), border: const OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(L.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(ctl.text)), child: Text(L.t('go'))),
        ],
      ),
    );
    if (line == null || line < 1 || !mounted) return;
    final t = doc.controller.text;
    var offset = 0;
    for (var n = 1; n < line; n++) {
      final i = t.indexOf('\n', offset);
      if (i < 0) break;
      offset = i + 1;
    }
    doc.controller.selection = TextSelection.collapsed(offset: offset);
    doc.focus.requestFocus();
    _reveal(offset);
  }

  // ---- find and replace ------------------------------------------------

  void _showFind({bool replace = false}) {
    final s = _sel;
    if (!s.isCollapsed) {
      final picked = s.textInside(doc.controller.text);
      if (!picked.contains('\n') && picked.length < 200) _findCtl.text = picked;
    }
    setState(() {
      _findOpen = true;
      _replaceOpen = replace || (_findOpen && _replaceOpen);
    });
    _findFocus.requestFocus();
    _findCtl.selection = TextSelection(baseOffset: 0, extentOffset: _findCtl.text.length);
    _recompute(jump: false);
  }

  void _closeFind() {
    if (!_findOpen) return;
    setState(() => _findOpen = false);
    doc.controller.setMatches(const [], -1);
    doc.focus.requestFocus();
  }

  /// Rebuilds the match list. With [jump] the nearest match is selected and shown.
  void _recompute({required bool jump}) {
    if (!mounted) return;
    final c = doc.controller;
    final q = _findCtl.text;
    if (!_findOpen || q.isEmpty) {
      c.setMatches(const [], -1);
      setState(() {});
      return;
    }
    var hay = c.text, needle = q;
    if (!_matchCase) {
      final lowHay = hay.toLowerCase(), lowNeedle = q.toLowerCase();
      // Lower-casing can change length for a few characters; offsets must stay valid.
      if (lowHay.length == hay.length && lowNeedle.length == q.length) {
        hay = lowHay;
        needle = lowNeedle;
      }
    }
    final list = <TextRange>[];
    var i = 0;
    while (true) {
      i = hay.indexOf(needle, i);
      if (i < 0) break;
      list.add(TextRange(start: i, end: i + needle.length));
      i += needle.length;
    }
    final from = c.selection.isValid ? c.selection.start : 0;
    var cur = list.indexWhere((m) => m.start >= from);
    if (cur < 0 && list.isNotEmpty) cur = 0;
    c.setMatches(list, cur);
    if (jump && cur >= 0) _reveal(list[cur].end);
    setState(() {});
  }

  void _step(int dir) {
    final c = doc.controller;
    if (!_findOpen) return _showFind();
    if (c.matches.isEmpty) return;
    final n = c.matches.length;
    final cur = ((c.current < 0 ? (dir > 0 ? -1 : 0) : c.current) + dir) % n;
    final m = c.matches[cur < 0 ? cur + n : cur];
    c.selection = TextSelection(baseOffset: m.start, extentOffset: m.end);
    c.setMatches(c.matches, cur < 0 ? cur + n : cur);
    _reveal(m.end);
    setState(() {});
  }

  void _replaceOne() {
    final c = doc.controller;
    if (c.current < 0 || c.current >= c.matches.length) return;
    final m = c.matches[c.current];
    final r = _replCtl.text;
    c.value = TextEditingValue(
      text: c.text.replaceRange(m.start, m.end, r),
      selection: TextSelection.collapsed(offset: m.start + r.length),
    );
    _recompute(jump: true);
  }

  void _replaceEvery() {
    final c = doc.controller;
    if (c.matches.isEmpty) return;
    final t = c.text, r = _replCtl.text;
    final b = StringBuffer();
    var pos = 0;
    for (final m in c.matches) {
      b
        ..write(t.substring(pos, m.start))
        ..write(r);
      pos = m.end;
    }
    b.write(t.substring(pos));
    c.value = TextEditingValue(text: b.toString(), selection: const TextSelection.collapsed(offset: 0));
    _recompute(jump: false);
  }

  // ---- shortcuts -------------------------------------------------------

  Map<ShortcutActivator, VoidCallback> get _bindings => {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): ws.newDoc,
        const SingleActivator(LogicalKeyboardKey.keyT, control: true): ws.newDoc,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true): _newWindow,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _open,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true): _saveAs,
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): () => _close(ws.active),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _showFind,
        const SingleActivator(LogicalKeyboardKey.keyH, control: true): () => _showFind(replace: true),
        const SingleActivator(LogicalKeyboardKey.f3): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.f3, shift: true): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.keyG, control: true): _goTo,
        const SingleActivator(LogicalKeyboardKey.f5): _timeDate,
        const SingleActivator(LogicalKeyboardKey.tab, control: true): () => ws.moveActive(1),
        const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): () => ws.moveActive(-1),
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () => _setZoom(_zoom + 0.1),
        const SingleActivator(LogicalKeyboardKey.numpadAdd, control: true): () => _setZoom(_zoom + 0.1),
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () => _setZoom(_zoom - 0.1),
        const SingleActivator(LogicalKeyboardKey.numpadSubtract, control: true): () => _setZoom(_zoom - 0.1),
        const SingleActivator(LogicalKeyboardKey.digit0, control: true): () => _setZoom(1),
      };

  // ---- build -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    doc.controller
      ..matchColor = scheme.tertiaryContainer
      ..currentColor = scheme.primary.withValues(alpha: 0.45);

    return CallbackShortcuts(
      bindings: _bindings,
      child: Scaffold(
        backgroundColor: scheme.surfaceContainer,
        body: DropTarget(
          onDragDone: (details) async {
            for (final f in details.files) {
              await ws.openPath(f.path);
            }
          },
          child: Column(
            children: [
              _titleBar(scheme),
              _menuRow(scheme),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _findOpen ? _findBar(scheme) : const SizedBox(width: double.infinity),
              ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(8, 4, 8, settings.showStatusBar ? 0 : 8),
                  child: Material(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(20),
                    clipBehavior: Clip.antiAlias,
                    child: Listener(
                      onPointerSignal: (e) {
                        if (e is PointerScrollEvent && _ctrl) {
                          _setZoom(_zoom + (e.scrollDelta.dy < 0 ? 0.1 : -0.1));
                        }
                      },
                      child: KeyedSubtree(
                        key: _editorKey,
                        child: EditorView(
                          key: ValueKey(doc.id),
                          doc: doc,
                          settings: settings,
                          zoom: _zoom,
                          lockScroll: _ctrl,
                          onTab: () => _replaceSelection('\t'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (settings.showStatusBar) _statusBar(scheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _titleBar(ColorScheme scheme) {
    return SizedBox(
      height: 46,
      child: LayoutBuilder(builder: (context, box) {
        final tabsMax = (box.maxWidth - 10 - 40 - 60 - 4 * 46).clamp(80.0, double.infinity);
        return Row(
          children: [
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: tabsMax),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [for (var i = 0; i < ws.docs.length; i++) _tab(i, scheme)]),
              ),
            ),
            IconButton(
              tooltip: L.t('newTab'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_rounded, size: 20),
              onPressed: ws.newDoc,
            ),
            Expanded(child: DragToMoveArea(child: const SizedBox.expand())),
            _caption(
              _alwaysOnTop ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              L.t(_alwaysOnTop ? 'unpinOnTop' : 'pinOnTop'),
              _toggleAlwaysOnTop,
              scheme,
              active: _alwaysOnTop,
            ),
            _caption(Icons.remove_rounded, L.t('minimize'), windowManager.minimize, scheme),
            _caption(
              _maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
              L.t('maximize'),
              () => _maximized ? windowManager.unmaximize() : windowManager.maximize(),
              scheme,
            ),
            _caption(Icons.close_rounded, L.t('close'), windowManager.close, scheme, danger: true),
          ],
        );
      }),
    );
  }

  Future<void> _toggleAlwaysOnTop() async {
    final next = !_alwaysOnTop;
    await windowManager.setAlwaysOnTop(next);
    if (mounted) setState(() => _alwaysOnTop = next);
  }

  Widget _caption(IconData icon, String tip, VoidCallback onTap, ColorScheme scheme,
      {bool danger = false, bool active = false}) {
    return SizedBox(
      width: 46,
      height: 46,
      child: InkWell(
        onTap: onTap,
        hoverColor: danger ? scheme.errorContainer : null,
        child: Tooltip(
          message: tip,
          waitDuration: const Duration(milliseconds: 700),
          child: Icon(
            icon,
            size: icon == Icons.filter_none_rounded ? 14 : (icon == Icons.push_pin_rounded || icon == Icons.push_pin_outlined ? 16 : 18),
            color: active ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _tab(int i, ColorScheme scheme) {
    final d = ws.docs[i];
    final selected = i == ws.active;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 7, 4, 5),
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons == kMiddleMouseButton) _close(i);
        },
        child: Material(
          color: selected ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => ws.setActive(i),
            child: Padding(
              padding: const EdgeInsets.only(left: 14, right: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 190),
                    child: ListenableBuilder(
                      listenable: d.controller,
                      builder: (_, _) => Text(
                        _titleOf(d),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: fg,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 15,
                      tooltip: L.t('closeTab'),
                      color: fg,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => _close(i),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  MenuItemButton _item(String key, VoidCallback? onPressed, {MenuSerializableShortcut? shortcut}) {
    return MenuItemButton(onPressed: onPressed, shortcut: shortcut, child: Text(L.t(key)));
  }

  static const _divider = Padding(
    padding: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
    child: Divider(height: 1),
  );

  Widget _menuRow(ColorScheme scheme) {
    SingleActivator key(LogicalKeyboardKey k, {bool ctrl = true, bool shift = false}) =>
        SingleActivator(k, control: ctrl, shift: shift);
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          const SizedBox(width: 6),
          Expanded(
            child: MenuBar(
              children: [
                SubmenuButton(
                  menuChildren: [
                    _item('newTab', ws.newDoc, shortcut: key(LogicalKeyboardKey.keyN)),
                    _item('newWindow', _newWindow, shortcut: key(LogicalKeyboardKey.keyN, shift: true)),
                    _item('open', _open, shortcut: key(LogicalKeyboardKey.keyO)),
                    _item('save', _save, shortcut: key(LogicalKeyboardKey.keyS)),
                    _item('saveAs', _saveAs, shortcut: key(LogicalKeyboardKey.keyS, shift: true)),
                    _divider,
                    _item('closeTab', () => _close(ws.active), shortcut: key(LogicalKeyboardKey.keyW)),
                    _item('exit', windowManager.close),
                  ],
                  child: Text(L.t('file')),
                ),
                SubmenuButton(
                  menuChildren: [
                    _item('undo', doc.undo.undo, shortcut: key(LogicalKeyboardKey.keyZ)),
                    _item('redo', doc.undo.redo, shortcut: key(LogicalKeyboardKey.keyY)),
                    _divider,
                    _item('cut', () => _copy(cut: true), shortcut: key(LogicalKeyboardKey.keyX)),
                    _item('copy', _copy, shortcut: key(LogicalKeyboardKey.keyC)),
                    _item('paste', _paste, shortcut: key(LogicalKeyboardKey.keyV)),
                    _item('delete', _delete, shortcut: key(LogicalKeyboardKey.delete, ctrl: false)),
                    _divider,
                    _item('find', _showFind, shortcut: key(LogicalKeyboardKey.keyF)),
                    _item('findNext', () => _step(1), shortcut: key(LogicalKeyboardKey.f3, ctrl: false)),
                    _item('findPrev', () => _step(-1),
                        shortcut: key(LogicalKeyboardKey.f3, ctrl: false, shift: true)),
                    _item('replace', () => _showFind(replace: true), shortcut: key(LogicalKeyboardKey.keyH)),
                    _item('goTo', _goTo, shortcut: key(LogicalKeyboardKey.keyG)),
                    _divider,
                    _item('selectAll', _selectAll, shortcut: key(LogicalKeyboardKey.keyA)),
                    _item('timeDate', _timeDate, shortcut: key(LogicalKeyboardKey.f5, ctrl: false)),
                  ],
                  child: Text(L.t('edit')),
                ),
                SubmenuButton(
                  menuChildren: [
                    CheckboxMenuButton(
                      value: settings.wordWrap,
                      onChanged: (v) => settings.update(() => settings.wordWrap = v ?? true),
                      child: Text(L.t('wordWrap')),
                    ),
                    CheckboxMenuButton(
                      value: settings.showStatusBar,
                      onChanged: (v) => settings.update(() => settings.showStatusBar = v ?? true),
                      child: Text(L.t('statusBar')),
                    ),
                    _divider,
                    _item('zoomIn', () => _setZoom(_zoom + 0.1), shortcut: key(LogicalKeyboardKey.equal)),
                    _item('zoomOut', () => _setZoom(_zoom - 0.1), shortcut: key(LogicalKeyboardKey.minus)),
                    _item('zoomReset', () => _setZoom(1), shortcut: key(LogicalKeyboardKey.digit0)),
                    _divider,
                    _item('font', () => showSettingsDialog(context, settings)),
                  ],
                  child: Text(L.t('view')),
                ),
              ],
            ),
          ),
          _saveState(scheme),
          IconButton(
            tooltip: L.t('settings'),
            icon: const Icon(Icons.palette_outlined, size: 20),
            onPressed: () => showSettingsDialog(context, settings),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _saveState(ColorScheme scheme) {
    final d = doc;
    if (d.isBlank) return const SizedBox.shrink();
    final (icon, key) = d.dirty
        ? (Icons.sync_rounded, 'unsaved')
        : (d.isUntitled ? (Icons.edit_note_rounded, 'draft') : (Icons.cloud_done_outlined, 'saved'));
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Row(
        children: [
          Icon(icon, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(L.t(key), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _findField(TextEditingController c, String hint, {FocusNode? focus, VoidCallback? onEnter, bool find = false}) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 260,
      height: 36,
      child: TextField(
        controller: c,
        focusNode: focus,
        style: const TextStyle(fontSize: 13.5),
        onChanged: find ? (_) => _recompute(jump: true) : null,
        onEditingComplete: () {},
        onSubmitted: (_) => onEnter?.call(),
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          filled: true,
          fillColor: scheme.surface,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
        ),
      ),
    );
  }

  Widget _findBar(ColorScheme scheme) {
    final c = doc.controller;
    final count = c.matches.isEmpty
        ? (_findCtl.text.isEmpty ? '' : L.t('noMatches'))
        : '${c.current + 1} / ${c.matches.length}';
    IconButton btn(IconData icon, String tip, VoidCallback? on, {bool selected = false}) => IconButton(
          tooltip: L.t(tip),
          visualDensity: VisualDensity.compact,
          isSelected: selected,
          style: selected ? IconButton.styleFrom(backgroundColor: scheme.secondaryContainer) : null,
          icon: Icon(icon, size: 19),
          onPressed: on,
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Column(
            children: [
              Row(
                children: [
                  btn(_replaceOpen ? Icons.expand_less_rounded : Icons.expand_more_rounded, 'replace',
                      () => setState(() => _replaceOpen = !_replaceOpen)),
                  _findField(_findCtl, L.t('findHint'), focus: _findFocus, onEnter: () => _step(1), find: true),
                  const SizedBox(width: 8),
                  btn(Icons.arrow_upward_rounded, 'findPrev', () => _step(-1)),
                  btn(Icons.arrow_downward_rounded, 'findNext', () => _step(1)),
                  btn(Icons.text_fields_rounded, 'matchCase', () {
                    setState(() => _matchCase = !_matchCase);
                    _recompute(jump: true);
                  }, selected: _matchCase),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(count,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                  ),
                  btn(Icons.close_rounded, 'close', _closeFind),
                ],
              ),
              if (_replaceOpen)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      const SizedBox(width: 40),
                      _findField(_replCtl, L.t('replaceHint'), onEnter: _replaceOne),
                      const SizedBox(width: 8),
                      FilledButton.tonal(onPressed: _replaceOne, child: Text(L.t('replaceOne'))),
                      const SizedBox(width: 6),
                      TextButton(onPressed: _replaceEvery, child: Text(L.t('replaceAll'))),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusBar(ColorScheme scheme) {
    final d = doc;
    final style = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    Widget pick<T>(String tip, String label, List<T> values, String Function(T) name, void Function(T) onPick) {
      return PopupMenuButton<T>(
        tooltip: L.t(tip),
        position: PopupMenuPosition.over,
        onSelected: onPick,
        itemBuilder: (_) => [for (final v in values) PopupMenuItem(value: v, height: 38, child: Text(name(v)))],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(label, style: style),
        ),
      );
    }

    return SizedBox(
      height: 32,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: [
            Expanded(
              child: ListenableBuilder(
                listenable: d.controller,
                builder: (_, _) {
                  final t = d.controller.text;
                  final s = d.controller.selection;
                  final off = (s.isValid ? s.extentOffset : 0).clamp(0, t.length);
                  var line = 1, lineStart = 0;
                  for (var i = 0; i < off; i++) {
                    if (t.codeUnitAt(i) == 0x0A) {
                      line++;
                      lineStart = i + 1;
                    }
                  }
                  return Text(
                    '${L.t('ln')} $line, ${L.t('col')} ${off - lineStart + 1}    ${t.length} ${L.t('chars')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  );
                },
              ),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _setZoom(1),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text('${(_zoom * 100).round()}%', style: style),
              ),
            ),
            pick<Eol>('lineEndings', d.eol.label, Eol.values, (v) => v.label, (v) {
              d.eol = v;
              ws.markChanged(d);
            }),
            pick<TextEnc>('encoding', d.enc.label, TextEnc.values, (v) => v.label, (v) {
              d.enc = v;
              ws.markChanged(d);
            }),
          ],
        ),
      ),
    );
  }
}
