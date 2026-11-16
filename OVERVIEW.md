# Mellow

A soft Material You notepad for Windows, written in Flutter. It behaves like the classic
Notepad (tabs, find/replace, go to line, word wrap, zoom, status bar) but saves by itself
and lets the user pick the colour scheme.

## Layout

| Path | What it holds |
| --- | --- |
| `lib/main.dart` | Entry point: single-instance handshake, window setup, `MellowApp` with the theme built from the seed colour. |
| `lib/instance.dart` | Loopback socket (port 47631) used by later launches to hand files to the main window. |
| `lib/workspace.dart` | `Workspace`: open tabs, autosave, drafts, session restore, tab expiry, hand-over from extra windows. |
| `lib/document.dart` | `Doc` (one tab) and `HighlightController` (paints search matches). |
| `lib/encoding.dart` | Detection and writing of UTF-8, UTF-8 BOM, UTF-16 LE/BE, Windows-1251, and line endings. |
| `lib/settings.dart` | `AppSettings` (JSON in the data folder), colour palette, font list, Windows accent colour. |
| `lib/l10n.dart` | Russian and English interface strings. |
| `lib/ui/home.dart` | Main screen: title bar with tabs, menus, find bar, status bar, shortcuts. |
| `lib/ui/editor.dart` | The text area of a tab. |
| `lib/ui/settings_dialog.dart` | Settings dialog and the custom colour picker. |
| `scripts/install.ps1` | Per-user install and file-type registration (`-Uninstall` removes it). |
| `scripts/make_icon.ps1` | Regenerates `windows/runner/resources/app_icon.ico`. |
| `test/` | Unit tests for encodings and the workspace. |
| `integration_test/app_test.dart` | End-to-end test that drives the real window. |

## Behaviour worth knowing

- **Autosave.** A named file is written about a second after typing stops, in its original
  encoding and line endings. There is no "save changes?" prompt anywhere.
- **Drafts.** Untitled tabs are stored in `%APPDATA%\Mellow\drafts\<id>.txt`. Closing a
  non-empty draft shows an Undo snackbar for 6 seconds, then the draft is deleted.
- **Session.** `%APPDATA%\Mellow\session.json` lists the open tabs; they come back on launch.
- **Expiry.** A tab untouched for longer than the setting (24 hours by default, 0 = never)
  is closed on launch and every 5 minutes while running; its draft is deleted. The active
  tab is never closed while the app runs.
- **One main window.** A second launch sends its file paths to the first and exits.
  "New window" starts a process with `--new-window`; it does not own the session and hands
  its tabs to the main window when it closes.
- **In memory, text always uses `\n`.** Line endings are converted on read and write.
- `MELLOW_DATA_DIR` overrides the data folder (used for testing).
- **Window setup.** The app draws its own title bar (`TitleBarStyle.hidden`). `setUpWindow()`
  in `lib/main.dart` retries the `window_manager` setup until `windowManager.getId() != 0`,
  first briefly before `runApp`, then on a background timer; otherwise the calls silently
  no-op and the system title bar shows on top of Mellow's own. The native runner opens the
  window at 980×680, so a window still at Flutter's 1280×720 default means setup never ran.
- **Font.** The UI uses Google Sans Flex (`kUiFont`), bundled as
  `assets/fonts/GoogleSansFlex.ttf` under the SIL Open Font License (`assets/fonts/OFL.txt`).

## Commands

Flutter is installed in `C:\src\flutter`; add `C:\src\flutter\bin` to `PATH` first.
Building needs Visual Studio Build Tools (C++ workload) and Windows Developer Mode.

```powershell
flutter test                                              # unit tests
flutter test integration_test/app_test.dart -d windows    # end-to-end, opens a window
flutter analyze
flutter build windows --release                           # build\windows\x64\runner\Release
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

## Known limits

- `window_manager` is used through its deprecated `legacy.dart` API; `flutter analyze`
  reports those deprecations. It should be moved to the new `Window` API.
- The editor is a plain Flutter `TextField`: files of several megabytes get slow, and files
  over 64 MB are refused. With word wrap off, very long files lay out slowly.
- Changes made to an open file by another program are not detected; the next autosave
  overwrites them.
- No printing.
- Windows does not let an app make itself the default; the user picks Mellow once in
  Settings → Apps → Default apps.
