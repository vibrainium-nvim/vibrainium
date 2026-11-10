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
    final tcp = VibrainiumDaemon.parseTcpEndpoint(socketPath);
    final Socket sock;
    if (tcp != null) {
      sock = await Socket.connect(tcp.$1, tcp.$2);
    } else {
      sock = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
    }
    return _TestSocketClient(sock);
  }

  Future<void> disconnect() async {
    await session.close();
    await socket.close();
    socket.destroy();
  }
}

Future<int> _findFreeTcpPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
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

    test('defaultSocketPath returns Unix socket on Unix and TCP loopback on Windows', () {
      final unixProd = VibrainiumDaemon.defaultSocketPath(isWindows: false);
      expect(unixProd, startsWith('/tmp/vibrainium-'));
      expect(unixProd, endsWith('-prod.sock'));
      expect(VibrainiumDaemon.parseTcpEndpoint(unixProd), isNull);

      final unixDev = VibrainiumDaemon.defaultSocketPath(
        devPackagePath: '/Users/dev/vibrainium',
        isWindows: false,
      );
      expect(unixDev, startsWith('/tmp/vibrainium-'));
      expect(unixDev, contains('-dev-'));
      expect(unixDev, endsWith('.sock'));

      final winProd = VibrainiumDaemon.defaultSocketPath(isWindows: true);
      final parsedProd = VibrainiumDaemon.parseTcpEndpoint(winProd);
      expect(parsedProd, isNotNull);
      expect(parsedProd!.$1, '127.0.0.1');
      expect(parsedProd.$2, inInclusiveRange(49152, 65534));

      final winDevA = VibrainiumDaemon.defaultSocketPath(
        devPackagePath: r'C:\projects\vibrainium',
        isWindows: true,
      );
      final winDevB = VibrainiumDaemon.defaultSocketPath(
        devPackagePath: r'C:\projects\other',
        isWindows: true,
      );
      expect(VibrainiumDaemon.parseTcpEndpoint(winDevA), isNotNull);
      expect(winDevA, isNot(equals(winProd)));
      expect(winDevA, isNot(equals(winDevB)));
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

    test(
      'supports TCP loopback endpoint (Windows mode) for start, multi-client RPC, single-instance guard, and stopRunningDaemon',
      () async {
        final port = await _findFreeTcpPort();
        final tcpEndpoint = '127.0.0.1:$port';

        expect(await VibrainiumDaemon.isSocketAlive(tcpEndpoint), isFalse);

        final daemon = VibrainiumDaemon(
          socketPath: tcpEndpoint,
          idleTimeout: const Duration(seconds: 5),
        );
        expect(await daemon.start(), isTrue);
        expect(await VibrainiumDaemon.isSocketAlive(tcpEndpoint), isTrue);

        final duplicate = VibrainiumDaemon(socketPath: tcpEndpoint);
        expect(await duplicate.start(), isFalse);

        final nvim = await _TestSocketClient.connect(tcpEndpoint);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(daemon.sessions, hasLength(1));

        expect(await nvim.session.request('vibrainium_action', ['repo_picker']), isTrue);
        expect(nvim.notifications, contains('No repositories discovered in workspace'));

        await VibrainiumDaemon.stopRunningDaemon(tcpEndpoint);
        await daemon.done.timeout(const Duration(seconds: 2));
        await nvim.disconnect();

        expect(await VibrainiumDaemon.isSocketAlive(tcpEndpoint), isFalse);
      },
    );

    test(
      'routes sendAgentHook (PreToolUse and PostToolUse) to the owning VibrainiumApp chat session',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('vibrainium_daemon_hook_');
        try {
          final targetFile = File('${tempDir.path}/edited.dart');
          await targetFile.writeAsString('int x = 1;\n');

          final daemon = VibrainiumDaemon(
            socketPath: socketPath,
            idleTimeout: const Duration(seconds: 5),
          );
          expect(await daemon.start(), isTrue);

          final nvimClient = await _TestSocketClient.connect(socketPath);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(daemon.sessions, hasLength(1));

          final app = daemon.sessions.single;
          final chat = await app.agentsPanel.createChat(
            AgentProviderKind.antigravity,
          );

          final rawHookJson =
              '{"toolCall":{"name":"edit_file","args":{"Path":"${targetFile.path}"}}}';

          // 1. PreToolUse captures baseline ('int x = 1;')
          final preOk = await VibrainiumDaemon.sendAgentHook(
            socketPath: socketPath,
            phase: 'pre',
            chatId: chat.id,
            provider: 'agy',
            rawJson: rawHookJson,
          );
          expect(preOk, isTrue);

          // 2. Modify file on disk and fire PostToolUse
          await targetFile.writeAsString('int x = 2;\n');
          final postOk = await VibrainiumDaemon.sendAgentHook(
            socketPath: socketPath,
            phase: 'post',
            chatId: chat.id,
            provider: 'agy',
            rawJson: rawHookJson,
          );
          expect(postOk, isTrue);

          expect(chat.changedFiles, hasLength(1));
          final normPath = AgentPathUtils.normalizePath(targetFile.path);
          expect(chat.baselines[normPath]!.lines, ['int x = 1;']);
          expect(chat.changedFiles[normPath]!.status, AgentFileStatus.modified);

          await VibrainiumDaemon.stopRunningDaemon(socketPath);
          await daemon.done.timeout(const Duration(seconds: 2));
          await nvimClient.disconnect();
        } finally {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        }
      },
    );
  });
}
