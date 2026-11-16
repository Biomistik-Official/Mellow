import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Loopback port the main Mellow window listens on for files opened later.
const int kInstancePort = 47631;
const String _hello = 'MELLOW1 ';

/// Sends [msg] to the main window. Returns false when no Mellow answers.
Future<bool> sendToPrimary(Map<String, dynamic> msg) async {
  Socket? s;
  try {
    s = await Socket.connect(InternetAddress.loopbackIPv4, kInstancePort,
        timeout: const Duration(milliseconds: 600));
    s.write('$_hello${jsonEncode(msg)}\n');
    await s.flush();
    final reply = await utf8.decoder.bind(s).first.timeout(const Duration(seconds: 3));
    return reply.startsWith('OK');
  } catch (_) {
    return false;
  } finally {
    s?.destroy();
  }
}

/// Tries to become the main window. Returns null when the port is taken.
Future<ServerSocket?> bindPrimary() async {
  try {
    return await ServerSocket.bind(InternetAddress.loopbackIPv4, kInstancePort);
  } catch (_) {
    return null;
  }
}

/// Handles messages from other Mellow processes with [onMessage].
void servePrimary(ServerSocket server, Future<void> Function(Map<String, dynamic>) onMessage) {
  server.listen((sock) {
    final buf = StringBuffer();
    var done = false;
    sock.cast<List<int>>().transform(utf8.decoder).listen((chunk) async {
      if (done) return;
      buf.write(chunk);
      final s = buf.toString();
      final nl = s.indexOf('\n');
      if (nl < 0) {
        if (s.length > 4 * 1024 * 1024) sock.destroy();
        return;
      }
      done = true;
      try {
        final line = s.substring(0, nl);
        if (!line.startsWith(_hello)) throw const FormatException();
        final msg = jsonDecode(line.substring(_hello.length)) as Map<String, dynamic>;
        await onMessage(msg);
        sock.write('OK\n');
        await sock.flush();
      } catch (_) {
        // Not a Mellow message: ignore it.
      } finally {
        sock.destroy();
      }
    }, onError: (_) => sock.destroy());
  });
}
