import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'encoding.dart';

/// Text controller that paints search matches behind the text.
class HighlightController extends TextEditingController {
  HighlightController({super.text});

  List<TextRange> matches = const [];
  int current = -1;
  Color matchColor = const Color(0x55FFD54F);
  Color currentColor = const Color(0xAAFF9800);

  void setMatches(List<TextRange> m, int cur) {
    if (matches.isEmpty && m.isEmpty && current == cur) return;
    matches = m;
    current = cur;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (matches.isEmpty || (withComposing && value.isComposingRangeValid)) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final t = text;
    final spans = <TextSpan>[];
    var pos = 0;
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      if (m.start < pos || m.end > t.length) continue;
      if (m.start > pos) spans.add(TextSpan(text: t.substring(pos, m.start)));
      spans.add(TextSpan(
        text: t.substring(m.start, m.end),
        style: TextStyle(backgroundColor: i == current ? currentColor : matchColor),
      ));
      pos = m.end;
    }
    if (pos < t.length) spans.add(TextSpan(text: t.substring(pos)));
    return TextSpan(style: style, children: spans);
  }
}

/// One open tab: either a file on disk ([path] set) or an untitled draft.
class Doc {
  Doc({
    required this.id,
    this.path,
    String text = '',
    this.enc = TextEnc.utf8,
    this.eol = Eol.crlf,
    required this.lastTouched,
  })  : controller = HighlightController(text: text),
        lastText = text;

  final String id;
  String? path;
  TextEnc enc;
  Eol eol;
  DateTime lastTouched;

  final HighlightController controller;
  final UndoHistoryController undo = UndoHistoryController();
  final FocusNode focus = FocusNode();

  /// Text as of the last change notification, used to tell edits from caret moves.
  String lastText;
  bool dirty = false;
  bool saveError = false;
  double scrollOffset = 0;
  Timer? saveTimer;
  Future<void>? saving;

  bool get isUntitled => path == null;
  bool get isBlank => path == null && controller.text.isEmpty;

  String? get fileName {
    final p = path;
    if (p == null) return null;
    final i = p.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? p : p.substring(i + 1);
  }

  /// First non-empty line of an untitled draft, used as its tab title.
  String? get firstLine {
    final t = controller.text;
    var start = 0;
    while (start < t.length) {
      var end = t.indexOf('\n', start);
      if (end < 0) end = t.length;
      final line = t.substring(start, end).trim();
      if (line.isNotEmpty) return line.length > 28 ? '${line.substring(0, 28)}…' : line;
      if (end > 400) break;
      start = end + 1;
    }
    return null;
  }

  void dispose() {
    saveTimer?.cancel();
    controller.dispose();
    undo.dispose();
    focus.dispose();
  }
}
