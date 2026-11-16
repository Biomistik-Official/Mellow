import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../l10n.dart';
import '../settings.dart';

Future<void> showSettingsDialog(BuildContext context, AppSettings settings) {
  return showDialog<void>(
    context: context,
    builder: (_) => ListenableBuilder(
      listenable: settings,
      builder: (context, _) => _SettingsDialog(settings: settings),
    ),
  );
}

class _SettingsDialog extends StatelessWidget {
  const _SettingsDialog({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = settings;

    Widget section(String key) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
          child: Text(L.t(key),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary)),
        );

    Widget card(List<Widget> children) => Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
          ),
        );

    Widget row(String label, Widget control, {String? hint}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(fontSize: 14)),
                    if (hint != null)
                      Text(hint, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              control,
            ],
          ),
        );

    DropdownButton<T> dropdown<T>(T value, Map<T, String> items, void Function(T) onPick) => DropdownButton<T>(
          value: items.containsKey(value) ? value : items.keys.first,
          underline: const SizedBox.shrink(),
          borderRadius: BorderRadius.circular(16),
          items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) {
            if (v != null) onPick(v);
          },
        );

    final customSelected = !s.useAccent && !kPalette.any((c) => c.toARGB32() == s.seed.toARGB32());

    return Dialog(
      backgroundColor: scheme.surfaceContainerLow,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SizedBox(width: 4),
                  Expanded(child: Text(L.t('settings'), style: Theme.of(context).textTheme.headlineSmall)),
                  IconButton(
                    tooltip: L.t('close'),
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      section('appearance'),
                      card([
                        row(
                          L.t('theme'),
                          SegmentedButton<ThemeMode>(
                            showSelectedIcon: false,
                            style: const ButtonStyle(visualDensity: VisualDensity.compact),
                            segments: [
                              ButtonSegment(value: ThemeMode.system, label: Text(L.t('themeSystem'))),
                              ButtonSegment(value: ThemeMode.light, label: Text(L.t('themeLight'))),
                              ButtonSegment(value: ThemeMode.dark, label: Text(L.t('themeDark'))),
                            ],
                            selected: {s.themeMode},
                            onSelectionChanged: (v) => s.update(() => s.themeMode = v.first),
                          ),
                        ),
                        row(
                          L.t('accent'),
                          Switch(value: s.useAccent, onChanged: (v) => s.update(() => s.useAccent = v)),
                          hint: L.t('accentHint'),
                        ),
                        const SizedBox(height: 6),
                        Text(L.t('color'), style: const TextStyle(fontSize: 14)),
                        const SizedBox(height: 10),
                        Opacity(
                          opacity: s.useAccent ? 0.4 : 1,
                          child: IgnorePointer(
                            ignoring: s.useAccent,
                            child: Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                for (final c in kPalette)
                                  _Swatch(
                                    color: c,
                                    selected: !s.useAccent && c.toARGB32() == s.seed.toARGB32(),
                                    onTap: () => s.update(() => s.seed = c),
                                  ),
                                _Swatch(
                                  color: customSelected ? s.seed : scheme.surfaceContainerHighest,
                                  selected: customSelected,
                                  icon: Icons.colorize_rounded,
                                  tooltip: L.t('customColor'),
                                  onTap: () async {
                                    final picked = await _pickColor(context, s.seed);
                                    if (picked != null) s.update(() => s.seed = picked);
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                      ]),
                      section('editor'),
                      card([
                        row(
                          L.t('fontFamily'),
                          dropdown<String>(
                            s.fontFamily,
                            {for (final f in kFonts) f: f},
                            (v) => s.update(() => s.fontFamily = v),
                          ),
                        ),
                        row(
                          '${L.t('fontSize')}: ${s.fontSize.round()}',
                          SizedBox(
                            width: 220,
                            child: Slider(
                              min: 8,
                              max: 40,
                              divisions: 32,
                              value: s.fontSize.clamp(8, 40),
                              onChanged: (v) => s.update(() => s.fontSize = v),
                            ),
                          ),
                        ),
                        row(
                          L.t('wordWrap'),
                          Switch(value: s.wordWrap, onChanged: (v) => s.update(() => s.wordWrap = v)),
                        ),
                        row(
                          L.t('statusBar'),
                          Switch(value: s.showStatusBar, onChanged: (v) => s.update(() => s.showStatusBar = v)),
                        ),
                      ]),
                      section('tabs'),
                      card([
                        row(
                          L.t('expiry'),
                          dropdown<int>(
                            s.expiryHours,
                            {
                              1: L.t('h1'),
                              6: L.t('h6'),
                              24: L.t('h24'),
                              72: L.t('d3'),
                              168: L.t('d7'),
                              0: L.t('never'),
                            },
                            (v) => s.update(() => s.expiryHours = v),
                          ),
                          hint: L.t('expiryHint'),
                        ),
                      ]),
                      section('language'),
                      card([
                        row(
                          L.t('language'),
                          SegmentedButton<String>(
                            showSelectedIcon: false,
                            style: const ButtonStyle(visualDensity: VisualDensity.compact),
                            segments: [
                              ButtonSegment(value: 'system', label: Text(L.t('langSystem'))),
                              const ButtonSegment(value: 'ru', label: Text('Русский')),
                              const ButtonSegment(value: 'en', label: Text('English')),
                            ],
                            selected: {s.language},
                            onSelectionChanged: (v) => s.update(() => s.language = v.first),
                          ),
                        ),
                      ]),
                      section('defaultApp'),
                      card([
                        row(
                          L.t('defaultApp'),
                          FilledButton.tonal(
                            onPressed: () => Process.run('cmd', ['/c', 'start', 'ms-settings:defaultapps']),
                            child: Text(L.t('openSettings')),
                          ),
                          hint: L.t('defaultAppHint'),
                        ),
                      ]),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected, required this.onTap, this.icon, this.tooltip});

  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black87;
    final child = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(selected ? 12 : 19),
        border: Border.all(color: selected ? scheme.onSurface : Colors.transparent, width: 2),
      ),
      child: selected
          ? Icon(Icons.check_rounded, size: 18, color: on)
          : (icon != null ? Icon(icon, size: 18, color: scheme.onSurfaceVariant) : null),
    );
    final tap = InkWell(onTap: onTap, borderRadius: BorderRadius.circular(19), child: child);
    return tooltip == null ? tap : Tooltip(message: tooltip!, child: tap);
  }
}

Future<Color?> _pickColor(BuildContext context, Color initial) {
  var hsv = HSVColor.fromColor(initial);
  if (hsv.saturation < 0.05) hsv = hsv.withSaturation(0.6).withValue(0.8);
  return showDialog<Color>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        Widget slider(String label, double value, double max, void Function(double) on) => Row(
              children: [
                SizedBox(width: 110, child: Text(label, style: const TextStyle(fontSize: 13))),
                Expanded(child: Slider(value: value, max: max, onChanged: (v) => setState(() => on(v)))),
              ],
            );
        final c = hsv.toColor();
        final hex = (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
        return AlertDialog(
          title: Text(L.t('customColor')),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  height: 64,
                  decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(20)),
                  alignment: Alignment.center,
                  child: Text(
                    '#$hex',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: ThemeData.estimateBrightnessForColor(c) == Brightness.dark
                          ? Colors.white
                          : Colors.black87,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                slider(L.t('hue'), hsv.hue, 360, (v) => hsv = hsv.withHue(v.clamp(0, 359.9))),
                slider(L.t('saturation'), hsv.saturation, 1, (v) => hsv = hsv.withSaturation(v)),
                slider(L.t('brightness'), hsv.value, 1, (v) => hsv = hsv.withValue(v)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(L.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, hsv.toColor()), child: Text(L.t('ok'))),
          ],
        );
      },
    ),
  );
}
