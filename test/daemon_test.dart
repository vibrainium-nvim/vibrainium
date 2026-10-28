import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vibrainium/vibrainium.dart';

class _TestSocketClient {
  final Socket socket;
  late final RpcSession session;
  final List<String> notifications = [];

  _TestSocketClient(this.socket) {
    final inputController = StreamController<List<int>>();
    socket.listen(
      inputController.add,
      onError: (_) => inputController.close(),
      onDone: () => inputController.close(),
    );
    session = RpcSession(
      input: inputController.stream,
      output: (bytes) => socket.add(bytes),
    );
    session.onRequest = (method, params) async {
      if (method == 'nvim_notify') {
        notifications.add(params.first.toString());
      }
      return null;
    };
  }

  static Future<_TestSocketClient> connect(String socketPath) async {
    final sock = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    return _TestSocketClient(sock);
  }

  Future<void> disconnect() async {
    await session.close();
    await socket.close();
    socket.destroy();
  }
}

void main() {
  group('VibrainiumDaemon', () {
    late String socketPath;

    setUp(() {
      final rand = DateTime.now().microsecondsSinceEpoch;
      socketPath = '/tmp/vibrainium-test-$rand.sock';
    });

    tearDown(() async {
      final f = File(socketPath);
      if (await f.exists()) {
        await f.delete();
      }
    });

    test(
      'keeps running when first Neovim quits while second Neovim is connected, and exits when last quits',
      () async {
        final daemon = VibrainiumDaemon(
          socketPath: socketPath,
          idleTimeout: const Duration(milliseconds: 200),
        );

        final started = await daemon.start();
        expect(started, isTrue);

        // Single-instance check: starting a duplicate daemon on the same socket returns false
        final duplicate = VibrainiumDaemon(socketPath: socketPath);
        expect(await duplicate.start(), isFalse);

        // Connect Neovim #1 and Neovim #2
        final nvim1 = await _TestSocketClient.connect(socketPath);
        final nvim2 = await _TestSocketClient.connect(socketPath);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(daemon.sessions, hasLength(2));

        // Both clients can perform RPC actions independently
        expect(await nvim1.session.request('vibrainium_action', ['repo_picker']), isTrue);
        expect(await nvim2.session.request('vibrainium_action', ['repo_picker']), isTrue);
        expect(nvim1.notifications, contains('No repositories discovered in workspace'));
        expect(nvim2.notifications, contains('No repositories discovered in workspace'));

        // Neovim #1 quits!
        await nvim1.disconnect();
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // Daemon must STILL be running because Neovim #2 is still connected!
        expect(daemon.sessions, hasLength(1));
        nvim2.notifications.clear();
        expect(await nvim2.session.request('vibrainium_action', ['repo_picker']), isTrue);
        expect(nvim2.notifications, contains('No repositories discovered in workspace'));

        // Now Neovim #2 (the last client) quits!
        await nvim2.disconnect();
        await daemon.done.timeout(const Duration(seconds: 2));
        expect(await File(socketPath).exists(), isFalse);
      },
    );
  });
}
