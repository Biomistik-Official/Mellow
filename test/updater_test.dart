import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mellow/updater.dart';

void main() {
  test('versions compare numerically and ignore a leading v', () {
    expect(compareVersions('1.0.0', '1.0.0'), 0);
    expect(compareVersions('v1.1.0', '1.0.9'), greaterThan(0));
    expect(compareVersions('1.0.10', '1.0.9'), greaterThan(0));
    expect(compareVersions('1.0', '1.0.1'), lessThan(0));
    expect(compareVersions('2.0.0', 'v10.0.0'), lessThan(0));
    expect(compareVersions('1.2.0-beta', '1.2.0'), 0);
  });

  test('latest release is read from the GitHub API answer', () {
    final r = parseRelease({
      'tag_name': 'v1.2.0',
      'draft': false,
      'prerelease': false,
      'assets': [
        {'name': 'notes.txt', 'browser_download_url': 'https://x/notes.txt', 'size': 3},
        {'name': 'Mellow-1.2.0-windows-x64.zip', 'browser_download_url': 'https://x/m.zip', 'size': 1234},
      ],
    });
    expect(r, isNotNull);
    expect(r!.version, '1.2.0');
    expect(r.zipUrl, 'https://x/m.zip');
    expect(r.size, 1234);
  });

  test('drafts, prereleases and releases without the zip are skipped', () {
    final zip = {'name': 'Mellow-1.2.0-windows-x64.zip', 'browser_download_url': 'u', 'size': 1};
    expect(parseRelease({'tag_name': 'v1.2.0', 'draft': true, 'assets': [zip]}), isNull);
    expect(parseRelease({'tag_name': 'v1.2.0', 'prerelease': true, 'assets': [zip]}), isNull);
    expect(parseRelease({'tag_name': 'v1.2.0', 'assets': []}), isNull);
    expect(parseRelease({'assets': [zip]}), isNull);
  });

  test('app version matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*([0-9.]+)', multiLine: true).firstMatch(pubspec);
    expect(m?.group(1), kAppVersion);
  });

  test('updates only run from the installed copy', () {
    expect(installedDirFor(r'C:\Users\u\AppData\Local\Programs\Mellow\mellow.exe', r'C:\Users\u\AppData\Local'),
        r'C:\Users\u\AppData\Local\Programs\Mellow');
    expect(installedDirFor(r'c:\users\U\appdata\local\programs\mellow\Mellow.exe', r'C:\Users\u\AppData\Local'),
        isNotNull);
    expect(installedDirFor(r'C:\Projects\Mellow\build\windows\x64\runner\Release\mellow.exe', r'C:\Users\u\AppData\Local'),
        isNull);
    expect(installedDirFor(r'C:\x\mellow.exe', null), isNull);
  });
}
