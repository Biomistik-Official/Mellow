import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../settings.dart';
import '../workspace.dart';

/// The text area of one tab.
class EditorView extends StatefulWidget {
  const EditorView({
    super.key,
    required this.doc,
    required this.settings,
    required this.zoom,
    required this.lockScroll,
    required this.onTab,
  });

  final Doc doc;
  final AppSettings settings;
  final double zoom;

  /// True while Ctrl is held, so the wheel zooms instead of scrolling.
  final bool lockScroll;
  final VoidCallback onTab;

  @override
  State<EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<EditorView> {
  late final ScrollController _v = ScrollController(initialScrollOffset: widget.doc.scrollOffset);
  final ScrollController _h = ScrollController();

  @override
  void initState() {
    super.initState();
    _v.addListener(() {
      if (_v.hasClients) widget.doc.scrollOffset = _v.offset;
    });
  }

  @override
  void dispose() {
    _v.dispose();
    _h.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = widget.settings;
    final field = TextField(
      controller: widget.doc.controller,
      focusNode: widget.doc.focus,
      undoController: widget.doc.undo,
      scrollController: _v,
      scrollPhysics: widget.lockScroll ? const NeverScrollableScrollPhysics() : null,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      inputFormatters: [FilteringTextInputFormatter.deny('\r')],
      cursorColor: scheme.primary,
      cursorWidth: 2,
      cursorRadius: const Radius.circular(2),
      style: TextStyle(
        fontFamily: s.fontFamily,
        fontFamilyFallback: const ['Consolas', 'Segoe UI'],
        fontSize: s.fontSize * widget.zoom,
        height: 1.4,
        color: scheme.onSurface,
      ),
      decoration: const InputDecoration(
        border: InputBorder.none,
        filled: false,
        isCollapsed: true,
        contentPadding: EdgeInsets.fromLTRB(22, 18, 22, 18),
      ),
    );

    final Widget body;
    if (s.wordWrap) {
      body = field;
    } else {
      body = LayoutBuilder(
        builder: (context, box) => Scrollbar(
          controller: _h,
          child: SingleChildScrollView(
            controller: _h,
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: box.maxWidth),
              child: IntrinsicWidth(child: SizedBox(height: box.maxHeight, child: field)),
            ),
          ),
        ),
      );
    }

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.tab): widget.onTab},
      child: body,
    );
  }
}
