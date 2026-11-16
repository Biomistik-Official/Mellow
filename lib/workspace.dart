import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';

import 'document.dart';
import 'encoding.dart';

export 'document.dart';

/// Largest file Mellow will open, in bytes.
const int kMaxFileSize = 64 * 1024 * 1024;

final RegExp _idPattern = RegExp(r'^[a-z0-9]{6,32}$');

/// True when a tab last touched at [last] should be closed. [hours] of 0 disables expiry.
bool isExpired(DateTime last, DateTime now, int hours) {
  if (hours <= 0) return false;
  return now.difference(last) > Duration(hours: hours);
}

/// Open tabs, autosave, drafts and session restore.
class Workspace extends ChangeNotifier {
  Workspace({
    required this.dataDir,
    required this.expiryHours,
    DateTime Function()? now,
    this.secondary = false,
  }) : now = now ?? DateTime.now;

  final Directory dataDir;
  final int Function() expiryHours;
  final DateTime Function() now;

  /// Extra windows do not own the session file; they hand their tabs to the main one.
  final bool secondary;

  final List<Doc> docs = [];
  int active = 0;

  /// Called with a message key and a detail (usually a path) when file IO fails.
  void Function(String key, String detail)? onError;

  /// Called after the text of a document changed.
  void Function(Doc doc)? onTextChanged;

  Timer? _sessionTimer;
  Timer? _expiryTimer;
  final Random _rnd = Random();

  Doc get current => docs[active];
  String get _sep => Platform.pathSeparator;
  Directory get draftsDir => Directory('${dataDir.path}${_sep}drafts');
  File get sessionFile => File('${dataDir.path}${_sep}session.json');
  String draftPath(String id) => '${draftsDir.path}$_sep$id.txt';

  String _newId() {
    final t = now().microsecondsSinceEpoch.toRadixString(36);
    final r = _rnd.nextInt(1 << 30).toRadixString(36).padLeft(6, '0');
    return '$t$r';
  }

  Doc _attach(Doc d) {
    d.controller.addListener(() => _onControllerChanged(d));
    return d;
  }

  void _onControllerChanged(Doc d) {
    final t = d.controller.text;
    if (identical(t, d.lastText) || t == d.lastText) return;
    d.lastText = t;
    d.lastTouched = now();
    final wasDirty = d.dirty;
    d.dirty = true;
    d.saveTimer?.cancel();
    d.saveTimer = Timer(const Duration(milliseconds: 900), () => save(d));
    onTextChanged?.call(d);
    if (!wasDirty) notifyListeners();
  }

  Doc _blank() => _attach(Doc(id: _newId(), lastTouched: now()));

  /// Adds an empty untitled tab and activates it.
  Doc newDoc() {
    final d = _blank();
    docs.add(d);
    active = docs.length - 1;
    notifyListeners();
    return d;
  }

  void setActive(int i) {
    if (i < 0 || i >= docs.length || i == active) return;
    active = i;
    current.lastTouched = now();
    notifyListeners();
    _scheduleSession();
  }

  void moveActive(int delta) {
    if (docs.length < 2) return;
    setActive((active + delta) % docs.length);
  }

  /// Opens [path] in a tab, or activates the tab that already has it.
  Future<bool> openPath(String path) async {
    final abs = File(path).absolute.path;
    final existing = docs.indexWhere((d) => d.path != null && d.path!.toLowerCase() == abs.toLowerCase());
    if (existing >= 0) {
      active = existing;
      current.lastTouched = now();
      notifyListeners();
      return true;
    }
    final Doc doc;
    try {
      final f = File(abs);
      if (await f.length() > kMaxFileSize) {
        onError?.call('errTooLarge', abs);
        return false;
      }
      final dec = decodeBytes(await f.readAsBytes());
      doc = _attach(Doc(
        id: _newId(),
        path: abs,
        text: dec.text,
        enc: dec.enc,
        eol: dec.eol,
        lastTouched: now(),
      ));
    } catch (_) {
      onError?.call('errOpen', abs);
      return false;
    }
    if (docs.length == 1 && docs.first.isBlank) {
      final old = docs.removeAt(0);
      scheduleMicrotask(old.dispose);
    }
    docs.add(doc);
    active = docs.length - 1;
    notifyListeners();
    _scheduleSession();
    return true;
  }

  /// Writes [d] now: to its file, or to the drafts folder when it has no name.
  Future<void> save(Doc d) {
    d.saveTimer?.cancel();
    final next = (d.saving ?? Future<void>.value()).then((_) => _doSave(d));
    d.saving = next;
    return next;
  }

  Future<void> _doSave(Doc d) async {
    if (!d.dirty) return;
    final text = d.controller.text;
    try {
      if (d.path != null) {
        if (d.enc == TextEnc.cp1251 && !canEncodeCp1251(text)) d.enc = TextEnc.utf8;
        await File(d.path!).writeAsBytes(encodeText(text, d.enc, d.eol), flush: true);
      } else if (text.isEmpty) {
        await _deleteDraft(d.id);
      } else {
        await draftsDir.create(recursive: true);
        await File(draftPath(d.id)).writeAsString(text, flush: true);
      }
      if (text == d.controller.text) d.dirty = false;
      d.saveError = false;
    } catch (_) {
      if (!d.saveError) onError?.call('errSave', d.path ?? d.id);
      d.saveError = true;
    }
    notifyListeners();
    _scheduleSession();
  }

  /// Gives [d] a new location on disk and saves it there.
  Future<void> saveAs(Doc d, String path) async {
    final wasDraft = d.path == null;
    d.path = File(path).absolute.path;
    d.dirty = true;
    d.lastTouched = now();
    await save(d);
    if (wasDraft && !d.saveError) await _deleteDraft(d.id);
    notifyListeners();
  }

  /// Marks [d] changed after its encoding or line endings were switched.
  void markChanged(Doc d) {
    d.dirty = true;
    d.lastTouched = now();
    save(d);
    notifyListeners();
  }

  /// Removes the tab at [i] and returns it so the close can be undone.
  /// Call [finalizeClose] once the undo window has passed.
  Future<Doc> closeAt(int i) async {
    final d = docs[i];
    await save(d);
    docs.removeAt(i);
    if (docs.isEmpty) docs.add(_blank());
    if (active > i || active >= docs.length) active = max(0, active - 1);
    notifyListeners();
    _scheduleSession();
    return d;
  }

  void reopen(Doc d, int index) {
    if (docs.contains(d)) return;
    if (docs.length == 1 && docs.first.isBlank) {
      final old = docs.removeAt(0);
      scheduleMicrotask(old.dispose);
    }
    final at = index.clamp(0, docs.length);
    docs.insert(at, d);
    active = at;
    d.lastTouched = now();
    notifyListeners();
    _scheduleSession();
  }

  Future<void> finalizeClose(Doc d) async {
    if (docs.contains(d)) return;
    if (d.path == null) await _deleteDraft(d.id);
    d.dispose();
  }

  Future<void> _deleteDraft(String id) async {
    try {
      final f = File(draftPath(id));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Map<String, dynamic> _entry(Doc d) => {
        'id': d.id,
        'path': d.path,
        'enc': d.enc.name,
        'eol': d.eol.name,
        'touched': d.lastTouched.millisecondsSinceEpoch,
        'sel': d.controller.selection.isValid ? d.controller.selection.baseOffset : 0,
      };

  /// Session entries for every tab worth keeping (blank untitled tabs are skipped).
  List<Map<String, dynamic>> exportTabs() => [
        for (final d in docs)
          if (!d.isBlank) _entry(d),
      ];

  Future<Doc?> _load(Map<String, dynamic> e) async {
    final id = e['id'];
    if (id is! String || !_idPattern.hasMatch(id)) return null;
    if (docs.any((d) => d.id == id)) return null;
    final touched = DateTime.fromMillisecondsSinceEpoch((e['touched'] as num?)?.toInt() ?? 0);
    final path = e['path'];
    try {
      Doc d;
      if (path is String) {
        final f = File(path);
        if (!await f.exists() || await f.length() > kMaxFileSize) return null;
        final dec = decodeBytes(await f.readAsBytes());
        d = Doc(id: id, path: path, text: dec.text, enc: dec.enc, eol: dec.eol, lastTouched: touched);
      } else {
        final f = File(draftPath(id));
        if (!await f.exists()) return null;
        d = Doc(
          id: id,
          text: await f.readAsString(),
          enc: TextEnc.values.asNameMap()[e['enc']] ?? TextEnc.utf8,
          eol: Eol.values.asNameMap()[e['eol']] ?? Eol.crlf,
          lastTouched: touched,
        );
      }
      final sel = (e['sel'] as num?)?.toInt() ?? 0;
      d.controller.selection = TextSelection.collapsed(offset: sel.clamp(0, d.controller.text.length));
      return _attach(d);
    } catch (_) {
      return null;
    }
  }

  /// Loads the previous session. Tabs untouched longer than the limit are dropped.
  Future<void> restore() async {
    String? activeId;
    if (!secondary) {
      try {
        final json = jsonDecode(await sessionFile.readAsString()) as Map<String, dynamic>;
        activeId = json['active'] as String?;
        final hours = expiryHours();
        for (final raw in (json['tabs'] as List? ?? const [])) {
          final e = Map<String, dynamic>.from(raw as Map);
          final touched = DateTime.fromMillisecondsSinceEpoch((e['touched'] as num?)?.toInt() ?? 0);
          if (isExpired(touched, now(), hours)) {
            final id = e['id'];
            if (e['path'] == null && id is String && _idPattern.hasMatch(id)) await _deleteDraft(id);
            continue;
          }
          final d = await _load(e);
          if (d != null) docs.add(d);
        }
      } catch (_) {
        // No session yet, or it is unreadable: start fresh.
      }
      await _sweepOldDrafts();
      _expiryTimer = Timer.periodic(const Duration(minutes: 5), (_) => closeExpired());
    }
    if (docs.isEmpty) docs.add(_blank());
    final i = docs.indexWhere((d) => d.id == activeId);
    active = i >= 0 ? i : docs.length - 1;
    notifyListeners();
  }

  /// Deletes draft files that no tab refers to and that are older than a week.
  Future<void> _sweepOldDrafts() async {
    try {
      if (!await draftsDir.exists()) return;
      final known = {for (final d in docs) '${d.id}.txt'};
      await for (final f in draftsDir.list()) {
        if (f is! File) continue;
        final name = f.path.substring(f.path.lastIndexOf(_sep) + 1);
        if (known.contains(name)) continue;
        if (now().difference(await f.lastModified()) > const Duration(days: 7)) await f.delete();
      }
    } catch (_) {}
  }

  /// Closes background tabs that passed the limit while the app was running.
  Future<void> closeExpired() async {
    final hours = expiryHours();
    final stale = [
      for (var i = 0; i < docs.length; i++)
        if (i != active && isExpired(docs[i].lastTouched, now(), hours)) docs[i],
    ];
    for (final d in stale) {
      final i = docs.indexOf(d);
      if (i < 0) continue;
      final closed = await closeAt(i);
      await finalizeClose(closed);
    }
  }

  /// Adds tabs handed over by another window.
  Future<void> adopt(List<dynamic> entries) async {
    var added = false;
    for (final raw in entries) {
      if (raw is! Map) continue;
      final e = Map<String, dynamic>.from(raw);
      final path = e['path'];
      if (path is String && docs.any((d) => d.path?.toLowerCase() == path.toLowerCase())) continue;
      final d = await _load(e);
      if (d == null) continue;
      if (docs.length == 1 && docs.first.isBlank) {
        final old = docs.removeAt(0);
        scheduleMicrotask(old.dispose);
        active = 0;
      }
      docs.add(d);
      added = true;
    }
    if (added) {
      notifyListeners();
      _scheduleSession();
    }
  }

  void _scheduleSession() {
    if (secondary) return;
    _sessionTimer?.cancel();
    _sessionTimer = Timer(const Duration(milliseconds: 400), persistSession);
  }

  Future<void> persistSession() async {
    if (secondary) return;
    _sessionTimer?.cancel();
    await _writeSession({'active': docs.isEmpty ? null : current.id, 'tabs': exportTabs()});
  }

  Future<void> _writeSession(Map<String, dynamic> data) async {
    try {
      await dataDir.create(recursive: true);
      final tmp = File('${sessionFile.path}.tmp');
      await tmp.writeAsString(jsonEncode(data), flush: true);
      await tmp.rename(sessionFile.path);
    } catch (_) {}
  }

  /// For an extra window with no main window to hand over to:
  /// appends its tabs to the stored session so they come back next launch.
  Future<void> appendToSessionFile() async {
    Map<String, dynamic> data = {'active': null, 'tabs': <dynamic>[]};
    try {
      data = jsonDecode(await sessionFile.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
    final tabs = List<dynamic>.from(data['tabs'] as List? ?? const []);
    tabs.addAll(exportTabs());
    data['tabs'] = tabs;
    await _writeSession(data);
  }

  /// Saves everything that is pending. Call before the window closes.
  Future<void> flushAll() async {
    for (final d in List<Doc>.from(docs)) {
      await save(d);
    }
    await persistSession();
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    _expiryTimer?.cancel();
    for (final d in docs) {
      d.dispose();
    }
    super.dispose();
  }
}
