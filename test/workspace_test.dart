import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mellow/encoding.dart';
import 'package:mellow/workspace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('mellow_test_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Workspace make({DateTime Function()? now, int hours = 24}) => Workspace(
        dataDir: Directory('${dir.path}${Platform.pathSeparator}data'),
        expiryHours: () => hours,
        now: now ?? DateTime.now,
      );

  test('isExpired respects the limit and 0 means never', () {
    final t = DateTime(2026, 1, 1, 12);
    expect(isExpired(t, t.add(const Duration(hours: 23)), 24), isFalse);
    expect(isExpired(t, t.add(const Duration(hours: 25)), 24), isTrue);
    expect(isExpired(t, t.add(const Duration(days: 900)), 0), isFalse);
  });

  test('untitled draft survives a restart', () async {
    final a = make();
    await a.restore();
    a.current.controller.text = 'hello draft';
    await a.flushAll();

    final b = make();
    await b.restore();
    expect(b.docs.length, 1);
    expect(b.current.path, isNull);
    expect(b.current.controller.text, 'hello draft');
    expect(b.current.dirty, isFalse);
  });

  test('tabs untouched longer than the limit are dropped with their drafts', () async {
    final a = make();
    await a.restore();
    a.current.controller.text = 'old draft';
    final id = a.current.id;
    await a.flushAll();
    expect(File(a.draftPath(id)).existsSync(), isTrue);

    final later = DateTime.now().add(const Duration(hours: 25));
    final b = make(now: () => later);
    await b.restore();
    expect(b.docs.length, 1);
    expect(b.current.controller.text, '');
    expect(File(b.draftPath(id)).existsSync(), isFalse);
  });

  test('expiry disabled keeps old tabs', () async {
    final a = make();
    await a.restore();
    a.current.controller.text = 'keep me';
    await a.flushAll();
    final later = DateTime.now().add(const Duration(days: 30));
    final b = make(now: () => later, hours: 0);
    await b.restore();
    expect(b.current.controller.text, 'keep me');
  });

  test('named file keeps its encoding and line endings on autosave', () async {
    final f = File('${dir.path}${Platform.pathSeparator}note.txt');
    f.writeAsBytesSync(encodeText('Привет\nмир', TextEnc.cp1251, Eol.crlf));

    final a = make();
    await a.restore();
    await a.openPath(f.path);
    expect(a.docs.length, 1, reason: 'empty untitled tab is replaced');
    expect(a.current.enc, TextEnc.cp1251);
    expect(a.current.eol, Eol.crlf);
    a.current.controller.text = 'Привет\nмир\nещё';
    await a.flushAll();
    expect(f.readAsBytesSync(), encodeText('Привет\nмир\nещё', TextEnc.cp1251, Eol.crlf));

    // Text that cp1251 cannot hold switches the file to UTF-8 instead of losing it.
    a.current.controller.text = '日本';
    await a.flushAll();
    expect(a.current.enc, TextEnc.utf8);
    expect(decodeBytes(f.readAsBytesSync()).text, '日本');

    // Named file is restored from session, opening it twice does not duplicate.
    final b = make();
    await b.restore();
    expect(b.docs.single.path, f.path);
    await b.openPath(f.path.toUpperCase());
    expect(b.docs.length, 1);
  });

  test('closing a tab can be undone, finalising deletes the draft', () async {
    final a = make();
    await a.restore();
    a.current.controller.text = 'draft';
    await a.flushAll();
    final id = a.current.id;
    final closed = await a.closeAt(0);
    expect(a.docs.length, 1);
    expect(a.current.id, isNot(id));
    a.reopen(closed, 0);
    expect(a.docs.first.id, id);
    final again = await a.closeAt(0);
    await a.finalizeClose(again);
    expect(File(a.draftPath(id)).existsSync(), isFalse);
  });

  test('adopted tabs from another window are appended', () async {
    final a = make();
    await a.restore();
    final second = Workspace(
      dataDir: a.dataDir,
      expiryHours: () => 24,
      now: DateTime.now,
      secondary: true,
    );
    await second.restore();
    second.current.controller.text = 'from second window';
    await second.flushAll();
    await a.adopt(second.exportTabs());
    expect(a.docs.any((d) => d.controller.text == 'from second window'), isTrue);
  });
}
