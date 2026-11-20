import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mellow/updater.dart';

/// Downloads the real latest release from GitHub and installs it into a temp folder.
/// Off by default; run with MELLOW_NETWORK_TESTS=1.
void main() {
  final enabled = Platform.environment['MELLOW_NETWORK_TESTS'] == '1';

  test('latest release downloads and installs over an old copy', () async {
    final root = Directory.systemTemp.createTempSync('mellow_upd_');
    final target = Directory('${root.path}\\install')..createSync();
    File('${target.path}\\mellow.exe').writeAsStringSync('old');
    final work = Directory('${root.path}\\work');
    final u = Updater(installDir: target.path, currentVersion: '0.0.1', workDir: work);

    expect(await u.check(), isTrue);
    expect(u.readyVersion, isNotNull);
    expect(u.readyZip!.existsSync(), isTrue);

    expect(await u.launchInstaller(relaunch: false), isTrue);
    expect(await u.launchInstaller(relaunch: false), isFalse, reason: 'runs once');

    final log = File('${work.path}\\update.log');
    for (var i = 0; i < 120 && !log.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    expect(log.readAsStringSync(), contains('installed'));
    expect(File('${target.path}\\mellow.exe').lengthSync(), greaterThan(10000));
    expect(File('${target.path}\\data\\app.so').existsSync(), isTrue);
    expect(u.readyZip!.existsSync(), isFalse, reason: 'zip is removed after install');
    root.deleteSync(recursive: true);
  }, skip: enabled ? false : 'set MELLOW_NETWORK_TESTS=1', timeout: const Timeout(Duration(minutes: 5)));

  test('nothing is downloaded when already up to date', () async {
    final root = Directory.systemTemp.createTempSync('mellow_upd_');
    final u = Updater(installDir: root.path, currentVersion: '999.0.0', workDir: Directory('${root.path}\\w'));
    expect(await u.check(), isFalse);
    expect(u.readyZip, isNull);
    expect(Directory('${root.path}\\w').existsSync(), isFalse);
    root.deleteSync(recursive: true);
  }, skip: enabled ? false : 'set MELLOW_NETWORK_TESTS=1');
}
