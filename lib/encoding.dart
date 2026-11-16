import 'dart:convert';
import 'dart:typed_data';

/// Text encodings Mellow can read and write.
enum TextEnc { utf8, utf8Bom, utf16le, utf16be, cp1251 }

/// Line ending styles. In memory text always uses '\n'.
enum Eol { crlf, lf, cr }

extension TextEncLabel on TextEnc {
  String get label => switch (this) {
        TextEnc.utf8 => 'UTF-8',
        TextEnc.utf8Bom => 'UTF-8 BOM',
        TextEnc.utf16le => 'UTF-16 LE',
        TextEnc.utf16be => 'UTF-16 BE',
        TextEnc.cp1251 => 'Windows-1251',
      };
}

extension EolLabel on Eol {
  String get label => switch (this) {
        Eol.crlf => 'Windows (CRLF)',
        Eol.lf => 'Unix (LF)',
        Eol.cr => 'Mac (CR)',
      };
  String get chars => switch (this) {
        Eol.crlf => '\r\n',
        Eol.lf => '\n',
        Eol.cr => '\r',
      };
}

class Decoded {
  const Decoded(this.text, this.enc, this.eol);
  final String text;
  final TextEnc enc;
  final Eol eol;
}

// Windows-1251 code points for bytes 0x80..0xBF (0xC0..0xFF map to U+0410..U+044F).
const List<int> _cp1251High = [
  0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
  0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x0098, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
  0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
  0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
  0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
  0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
];

final Map<int, int> _cp1251Reverse = {
  for (var i = 0; i < _cp1251High.length; i++) _cp1251High[i]: 0x80 + i,
};

String decodeCp1251(List<int> bytes) {
  final out = Uint16List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    out[i] = b < 0x80 ? b : (b >= 0xC0 ? 0x0410 + (b - 0xC0) : _cp1251High[b - 0x80]);
  }
  return String.fromCharCodes(out);
}

int _cp1251Byte(int unit) {
  if (unit < 0x80) return unit;
  if (unit >= 0x0410 && unit <= 0x044F) return unit - 0x0410 + 0xC0;
  return _cp1251Reverse[unit] ?? -1;
}

bool canEncodeCp1251(String text) {
  for (var i = 0; i < text.length; i++) {
    if (_cp1251Byte(text.codeUnitAt(i)) < 0) return false;
  }
  return true;
}

String _decodeUtf16(Uint8List b, int start, {required bool little}) {
  final n = (b.length - start) ~/ 2;
  final units = Uint16List(n);
  for (var i = 0; i < n; i++) {
    final a = b[start + i * 2], c = b[start + i * 2 + 1];
    units[i] = little ? (a | (c << 8)) : ((a << 8) | c);
  }
  return String.fromCharCodes(units);
}

bool _looksLikeUtf16Le(Uint8List b) {
  if (b.length < 4 || b.length.isOdd) return false;
  final n = b.length < 2000 ? b.length : 2000;
  var zeros = 0;
  for (var i = 1; i < n; i += 2) {
    if (b[i] == 0) zeros++;
  }
  return zeros * 2 > (n ~/ 2);
}

Decoded _finish(String raw, TextEnc enc) {
  var crlf = 0, lf = 0, cr = 0;
  for (var i = 0; i < raw.length; i++) {
    final u = raw.codeUnitAt(i);
    if (u == 0x0D) {
      if (i + 1 < raw.length && raw.codeUnitAt(i + 1) == 0x0A) {
        crlf++;
        i++;
      } else {
        cr++;
      }
    } else if (u == 0x0A) {
      lf++;
    }
  }
  var eol = Eol.crlf;
  if (lf > crlf && lf >= cr) {
    eol = Eol.lf;
  } else if (cr > crlf && cr > lf) {
    eol = Eol.cr;
  }
  final text = (crlf == 0 && cr == 0) ? raw : raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return Decoded(text, enc, eol);
}

/// Detects the encoding and line endings of [bytes] and returns text with '\n' endings.
Decoded decodeBytes(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return _finish(utf8.decode(bytes.sublist(3), allowMalformed: true), TextEnc.utf8Bom);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _finish(_decodeUtf16(bytes, 2, little: true), TextEnc.utf16le);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _finish(_decodeUtf16(bytes, 2, little: false), TextEnc.utf16be);
  }
  if (_looksLikeUtf16Le(bytes)) {
    return _finish(_decodeUtf16(bytes, 0, little: true), TextEnc.utf16le);
  }
  try {
    return _finish(utf8.decode(bytes), TextEnc.utf8);
  } on FormatException {
    return _finish(decodeCp1251(bytes), TextEnc.cp1251);
  }
}

/// Encodes in-memory [text] ('\n' endings) for writing to disk.
Uint8List encodeText(String text, TextEnc enc, Eol eol) {
  final s = eol == Eol.lf ? text : text.replaceAll('\n', eol.chars);
  switch (enc) {
    case TextEnc.utf8:
      return Uint8List.fromList(utf8.encode(s));
    case TextEnc.utf8Bom:
      return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(s)]);
    case TextEnc.utf16le:
    case TextEnc.utf16be:
      final little = enc == TextEnc.utf16le;
      final out = Uint8List(2 + s.length * 2);
      out[0] = little ? 0xFF : 0xFE;
      out[1] = little ? 0xFE : 0xFF;
      for (var i = 0; i < s.length; i++) {
        final u = s.codeUnitAt(i);
        out[2 + i * 2] = little ? (u & 0xFF) : (u >> 8);
        out[3 + i * 2] = little ? (u >> 8) : (u & 0xFF);
      }
      return out;
    case TextEnc.cp1251:
      final out = Uint8List(s.length);
      for (var i = 0; i < s.length; i++) {
        final b = _cp1251Byte(s.codeUnitAt(i));
        out[i] = b < 0 ? 0x3F : b;
      }
      return out;
  }
}
