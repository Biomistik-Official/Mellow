import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mellow/encoding.dart';

void main() {
  test('plain UTF-8 is detected and line endings are normalised', () {
    final d = decodeBytes(Uint8List.fromList(utf8.encode('Привет\r\nмир\r\n')));
    expect(d.text, 'Привет\nмир\n');
    expect(d.enc, TextEnc.utf8);
    expect(d.eol, Eol.crlf);
  });

  test('UTF-8 BOM is detected and stripped', () {
    final d = decodeBytes(Uint8List.fromList([0xEF, 0xBB, 0xBF, 0x68, 0x69]));
    expect(d.text, 'hi');
    expect(d.enc, TextEnc.utf8Bom);
  });

  test('UTF-16 LE and BE with BOM', () {
    final le = decodeBytes(Uint8List.fromList([0xFF, 0xFE, 0x1F, 0x04, 0x41, 0x00]));
    expect(le.text, 'ПA');
    expect(le.enc, TextEnc.utf16le);
    final be = decodeBytes(Uint8List.fromList([0xFE, 0xFF, 0x04, 0x1F, 0x00, 0x41]));
    expect(be.text, 'ПA');
    expect(be.enc, TextEnc.utf16be);
  });

  test('invalid UTF-8 falls back to Windows-1251', () {
    // "Привет" in cp1251
    final d = decodeBytes(Uint8List.fromList([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x0A]));
    expect(d.text, 'Привет\n');
    expect(d.enc, TextEnc.cp1251);
    expect(d.eol, Eol.lf);
  });

  test('cp1251 round trip including ё and №', () {
    const s = 'Ёжик № 5 — «ёлка»';
    expect(canEncodeCp1251(s), isTrue);
    final bytes = encodeText(s, TextEnc.cp1251, Eol.lf);
    expect(bytes.length, s.length);
    expect(decodeCp1251(bytes), s);
    expect(canEncodeCp1251('日本'), isFalse);
  });

  test('encode writes BOMs and chosen line endings', () {
    expect(encodeText('a\nb', TextEnc.utf8, Eol.crlf), [0x61, 0x0D, 0x0A, 0x62]);
    expect(encodeText('a\nb', TextEnc.utf8, Eol.lf), [0x61, 0x0A, 0x62]);
    expect(encodeText('a', TextEnc.utf8Bom, Eol.lf), [0xEF, 0xBB, 0xBF, 0x61]);
    expect(encodeText('a', TextEnc.utf16le, Eol.lf), [0xFF, 0xFE, 0x61, 0x00]);
    expect(encodeText('a', TextEnc.utf16be, Eol.lf), [0xFE, 0xFF, 0x00, 0x61]);
  });

  test('empty file defaults to UTF-8 with CRLF', () {
    final d = decodeBytes(Uint8List(0));
    expect(d.text, '');
    expect(d.enc, TextEnc.utf8);
    expect(d.eol, Eol.crlf);
  });

  test('lone CR and mixed endings are normalised', () {
    final d = decodeBytes(Uint8List.fromList('a\rb\rc'.codeUnits));
    expect(d.text, 'a\nb\nc');
    expect(d.eol, Eol.cr);
  });
}
