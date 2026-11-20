import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Keep in sync with `version:` in pubspec.yaml (a unit test checks it).
const kAppVersion = '1.1.0';
const kRepo = 'Biomistik-Official/Mellow';
const kLatestReleaseUrl = 'https://api.github.com/repos/$kRepo/releases/latest';

/// Compares dotted versions numerically; a leading `v` and any `-suffix` are ignored.
int compareVersions(String a, String b) {
  List<int> parts(String v) {
    v = v.trim();
    if (v.startsWith('v') || v.startsWith('V')) v = v.substring(1);
    v = v.split(RegExp(r'[-+]')).first;
    return [for (final p in v.split('.')) int.tryParse(p) ?? 0];
  }

  final x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

class ReleaseInfo {
  const ReleaseInfo(this.version, this.zipUrl, this.size);
  final String version;
  final String zipUrl;
  final int size;
}

/// Picks the Windows zip out of a GitHub "latest release" answer.
ReleaseInfo? parseRelease(Map<String, dynamic> json) {
  final tag = json['tag_name'];
  if (tag is! String || json['draft'] == true || json['prerelease'] == true) return null;
  final assets = json['assets'];
  if (assets is! List) return null;
  for (final a in assets) {
    if (a is! Map) continue;
    final name = a['name'], url = a['browser_download_url'], size = a['size'];
    if (name is String && name.endsWith('-windows-x64.zip') && url is String && size is int) {
      final v = tag.startsWith('v') ? tag.substring(1) : tag;
      return ReleaseInfo(v, url, size);
    }
  }
  return null;
}

/// The install folder when [exePath] is the copy install.ps1 put in
/// %LOCALAPPDATA%\Programs\Mellow, else null (dev builds never update themselves).
String? installedDirFor(String exePath, String? localAppData) {
  if (localAppData == null || localAppData.isEmpty) return null;
  final dir = File(exePath).parent.path;
  final expected = '$localAppData\\Programs\\Mellow';
  return dir.toLowerCase() == expected.toLowerCase() ? dir : null;
}

/// Checks GitHub for a newer release, downloads its zip in the background and,
/// once Mellow closes, swaps the files in the install folder.
class Updater extends ChangeNotifier {
  Updater({
    required this.installDir,
    this.currentVersion = kAppVersion,
    this.apiUrl = kLatestReleaseUrl,
    Directory? workDir,
  }) : workDir = workDir ?? Directory('${Directory.systemTemp.path}\\Mellow-update');

  /// Null outside the installed copy.
  static Updater? forThisProcess() {
    final dir = installedDirFor(Platform.resolvedExecutable, Platform.environment['LOCALAPPDATA']);
    return dir == null ? null : Updater(installDir: dir);
  }

  final String installDir;
  final String currentVersion;
  final String apiUrl;
  final Directory workDir;

  String? readyVersion;
  File? readyZip;
  bool _checking = false;
  bool _launched = false;
  Timer? _timer;

  /// Checks now (after a short delay so startup stays quick) and then every [every].
  void start({Duration first = const Duration(seconds: 5), Duration every = const Duration(hours: 6)}) {
    Timer(first, check);
    _timer = Timer.periodic(every, (_) => check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Returns true when an update is downloaded and waiting. Never throws.
  Future<bool> check() async {
    if (_checking || _launched) return readyZip != null;
    _checking = true;
    final client = HttpClient()..userAgent = 'Mellow-updater';
    try {
      final req = await client.getUrl(Uri.parse(apiUrl));
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return readyZip != null;
      }
      final body = await res.transform(utf8.decoder).join();
      final info = parseRelease(jsonDecode(body) as Map<String, dynamic>);
      if (info == null || compareVersions(info.version, currentVersion) <= 0) return readyZip != null;
      if (readyVersion != null && compareVersions(info.version, readyVersion!) <= 0) return true;

      workDir.createSync(recursive: true);
      final zip = File('${workDir.path}\\Mellow-${info.version}.zip');
      if (!zip.existsSync() || zip.lengthSync() != info.size) {
        final part = File('${zip.path}.part');
        final dl = await client.getUrl(Uri.parse(info.zipUrl));
        final dres = await dl.close().timeout(const Duration(seconds: 30));
        if (dres.statusCode != 200) {
          await dres.drain<void>();
          return readyZip != null;
        }
        await dres.pipe(part.openWrite()).timeout(const Duration(minutes: 10));
        if (part.lengthSync() != info.size) {
          part.deleteSync();
          return readyZip != null;
        }
        if (zip.existsSync()) zip.deleteSync();
        part.renameSync(zip.path);
      }
      readyVersion = info.version;
      readyZip = zip;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Update check failed: $e');
      return readyZip != null;
    } finally {
      client.close(force: true);
      _checking = false;
    }
  }

  /// Starts a hidden PowerShell that waits for every Mellow from [installDir] to exit,
  /// unpacks the downloaded zip over it and, with [relaunch], starts Mellow again.
  /// The caller closes its window afterwards. Runs at most once per process.
  Future<bool> launchInstaller({required bool relaunch}) async {
    final zip = readyZip;
    if (zip == null || _launched || !zip.existsSync()) return false;
    _launched = true;
    workDir.createSync(recursive: true);
    final script = File('${workDir.path}\\apply-update.ps1')..writeAsStringSync(applyScript);
    final launcher = File('${workDir.path}\\apply-update.vbs')
      ..writeAsStringSync(launcherScript(script.path, zip.path, installDir, relaunch: relaunch));
    // wscript has no console and returns at once, leaving PowerShell running on its own:
    // no window flashes and the installer outlives Mellow. A detached PowerShell started
    // straight from Dart has no console and can fail to start at all.
    final p = await Process.start('wscript.exe', ['//B', '//Nologo', launcher.path]);
    await p.exitCode.timeout(const Duration(seconds: 10), onTimeout: () => 0);
    return true;
  }
}

/// VBScript that starts the apply script in a hidden PowerShell window.
String launcherScript(String script, String zip, String target, {required bool relaunch}) {
  String q(String s) => '""$s""'; // a quoted argument inside a VBScript string
  final cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden '
      '-File ${q(script)} -Zip ${q(zip)} -Target ${q(target)}${relaunch ? ' -Relaunch' : ''}';
  return 'CreateObject("WScript.Shell").Run "$cmd", 0, False\r\n';
}

const applyScript = r'''
# Written by Mellow's updater. Waits for Mellow to close, then unpacks the new release over it.
param([string]$Zip, [string]$Target, [switch]$Relaunch)
$ErrorActionPreference = 'Stop'
$exe = Join-Path $Target 'mellow.exe'
$work = Split-Path $Zip
$log = Join-Path $work 'update.log'
try {
    # Every window is its own process; wait for all of them (at most 10 minutes).
    $deadline = (Get-Date).AddMinutes(10)
    while (Get-Process mellow -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }) {
        if ((Get-Date) -gt $deadline) { throw 'Mellow is still running' }
        Start-Sleep -Milliseconds 300
    }
    $tmp = Join-Path $work 'unpacked'
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $Zip -DestinationPath $tmp -Force
    $src = (Get-ChildItem $tmp -Recurse -Filter mellow.exe | Select-Object -First 1).DirectoryName
    if (-not $src) { throw 'mellow.exe is not in the archive' }
    Copy-Item (Join-Path $src '*') $Target -Recurse -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
    "$(Get-Date -Format s) installed $Zip" | Add-Content $log
} catch {
    "$(Get-Date -Format s) failed: $_" | Add-Content $log
}
if ($Relaunch) { Start-Process $exe }
''';
