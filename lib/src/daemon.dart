import 'dart:async';
import 'dart:io';

import 'package:viagent/viagent.dart';
import 'package:vivcs/vivcs.dart';

import 'app.dart';

/// Multi-client Unix domain socket (or TCP loopback on Windows) daemon that manages multiple Neovim instances.
class VibrainiumDaemon {
  final String socketPath;
  final String? devPackagePath;
  final Duration idleTimeout;
  final List<Vcs> vcsList;

  ServerSocket? _server;
  final Set<VibrainiumApp> sessions = {};
  final Set<Socket> _sockets = {};
  Timer? _idleTimer;
  final Completer<void> _doneCompleter = Completer<void>();

  VibrainiumDaemon({
    required this.socketPath,
    this.devPackagePath,
    this.idleTimeout = const Duration(seconds: 2),
    this.vcsList = const [Git(), Svn()],
  });

  /// Completes when the daemon stops.
  Future<void> get done => _doneCompleter.future;

  static int _djb2Hash(String input) {
    var hash = 5381;
    for (final unit in input.codeUnits) {
      hash = ((hash << 5) + hash) ^ unit;
    }
    return hash & 0xffffffff;
  }

  /// Parses [socketPath] as a TCP `(host, port)` endpoint if it matches
  /// `127.0.0.1:<port>` or `localhost:<port>`, or returns `null` for Unix socket paths.
  static (String, int)? parseTcpEndpoint(String socketPath) {
    final match = RegExp(r'^(127\.0\.0\.1|localhost):(\d+)$').firstMatch(socketPath);
    if (match == null) return null;
    final host = match.group(1)!;
    final port = int.tryParse(match.group(2)!);
    if (port == null || port < 0 || port > 65535) return null;
    return (host, port);
  }

  /// Computes a deterministic daemon endpoint:
  /// - On Unix (macOS/Linux): Unix domain socket path `/tmp/vibrainium-...sock` (< 100 chars for macOS SUN_LEN limit).
  /// - On Windows: Loopback TCP endpoint `127.0.0.1:<port>` in dynamic range `49152..65534`.
  static String defaultSocketPath({
    String? devPackagePath,
    bool? isWindows,
  }) {
    final windows = isWindows ?? Platform.isWindows;
    final user = Platform.environment['USER'] ??
        Platform.environment['USERNAME'] ??
        'default';
    if (windows) {
      final key = devPackagePath == null ? '$user:prod' : '$user:dev:$devPackagePath';
      final hash = _djb2Hash(key);
      final port = 49152 + (hash % 16383);
      return '127.0.0.1:$port';
    }
    if (devPackagePath == null) {
      return '/tmp/vibrainium-$user-prod.sock';
    }
    final hex = _djb2Hash(devPackagePath).toRadixString(16).padLeft(8, '0');
    return '/tmp/vibrainium-$user-dev-$hex.sock';
  }

  /// Returns true if an existing `vibrainium` daemon is actively listening on [socketPath].
  static Future<bool> isSocketAlive(String socketPath) async {
    final tcp = parseTcpEndpoint(socketPath);
    if (tcp != null) {
      final (host, port) = tcp;
      if (port <= 0) return false;
      try {
        final socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(milliseconds: 250),
        );
        await socket.close();
        socket.destroy();
        return true;
      } catch (_) {
        return false;
      }
    }

    final type = await FileSystemEntity.type(socketPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    try {
      final socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
        timeout: const Duration(milliseconds: 250),
      );
      await socket.close();
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Sends a shutdown signal to a running daemon on [socketPath] if alive.
  static Future<void> stopRunningDaemon(String socketPath) async {
    final tcp = parseTcpEndpoint(socketPath);
    if (tcp != null) {
      final (host, port) = tcp;
      if (port <= 0) return;
      try {
        final socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(milliseconds: 250),
        );
        socket.add(MsgpackCodec.encode([2, 'vibrainium_shutdown', <Object?>[]]));
        await socket.flush();
        await socket.close();
        socket.destroy();
      } catch (_) {}
      return;
    }

    final type = await FileSystemEntity.type(socketPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    try {
      final socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
        timeout: const Duration(milliseconds: 250),
      );
      socket.add(MsgpackCodec.encode([2, 'vibrainium_shutdown', <Object?>[]]));
      await socket.flush();
      await socket.close();
      socket.destroy();
    } catch (_) {
      try {
        await File(socketPath).delete();
      } catch (_) {}
    }
  }

  /// Connects to a running daemon on [socketPath], delivers a `vibrainium_agent_hook`
  /// event (`PreToolUse` or `PostToolUse`), and waits for processing to complete.
  static Future<bool> sendAgentHook({
    required String socketPath,
    required String phase,
    required String chatId,
    required String provider,
    required String rawJson,
  }) async {
    Socket? socket;
    try {
      final tcp = parseTcpEndpoint(socketPath);
      if (tcp != null) {
        final (host, port) = tcp;
        if (port <= 0) return false;
        socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(milliseconds: 500),
        );
      } else {
        final type = await FileSystemEntity.type(
          socketPath,
          followLinks: false,
        );
        if (type == FileSystemEntityType.notFound) return false;
        socket = await Socket.connect(
          InternetAddress(socketPath, type: InternetAddressType.unix),
          0,
          timeout: const Duration(milliseconds: 500),
        );
      }

      final inputController = StreamController<List<int>>();
      socket.listen(
        inputController.add,
        onError: (_) => inputController.close(),
        onDone: () => inputController.close(),
      );

      final rpc = RpcSession(
        input: inputController.stream,
        output: (bytes) {
          try {
            socket?.add(bytes);
          } catch (_) {}
        },
      );

      await rpc
          .request('vibrainium_agent_hook', [
            phase,
            chatId,
            provider,
            rawJson,
          ])
          .timeout(const Duration(seconds: 3));

      await rpc.close();
      await socket.flush();
      await socket.close();
      socket.destroy();
      return true;
    } catch (_) {
      try {
        socket?.destroy();
      } catch (_) {}
      return false;
    }
  }

  /// Routes a `vibrainium_agent_hook` payload across all active [sessions] to
  /// the [VibrainiumApp] instance that owns `chatId`.
  Future<bool> dispatchAgentHook(List<Object?> params) async {
    if (params.length < 3) return false;
    final phase = params[0]?.toString() ?? 'post';
    final chatId = params[1]?.toString() ?? '';
    final prov = AgentProviderKind.fromString(params[2]?.toString() ?? 'agy');
    final rawJson = params.length > 3 ? params[3]?.toString() ?? '' : '';
    final parsed = AgentHookConfig.parseHookStdin(
      rawJson: rawJson,
      phase: phase,
      chatId: chatId,
      provider: prov,
    );
    if (parsed == null) return false;

    var handled = false;
    for (final app in sessions.toList()) {
      if (app.agentsPanel.findSession(chatId) != null) {
        await app.agentsPanel.handleHookEvent(parsed);
        handled = true;
      }
    }
    return handled;
  }

  /// Starts listening on [socketPath].
  /// Returns `false` if another daemon is already listening on [socketPath].
  Future<bool> start() async {
    if (await isSocketAlive(socketPath)) {
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
      return false;
    }

    final tcp = parseTcpEndpoint(socketPath);
    final ServerSocket server;
    if (tcp != null) {
      final (host, port) = tcp;
      server = await ServerSocket.bind(host, port);
    } else {
      final existingType = await FileSystemEntity.type(socketPath, followLinks: false);
      if (existingType != FileSystemEntityType.notFound) {
        try {
          await File(socketPath).delete();
        } catch (_) {}
      }

      server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
    }
    _server = server;

    server.listen(
      _handleClientSocket,
      onDone: () {
        if (!_doneCompleter.isCompleted) {
          _doneCompleter.complete();
        }
      },
      onError: (_) {},
    );

    _scheduleIdleCheck();
    return true;
  }

  void _handleClientSocket(Socket socket) {
    _idleTimer?.cancel();
    _idleTimer = null;
    _sockets.add(socket);

    late final RpcSession rpcSession;
    late final VibrainiumApp app;

    void cleanupClient() {
      _sockets.remove(socket);
      sessions.remove(app);
      socket.destroy();
      if (sessions.isEmpty) {
        _scheduleIdleCheck();
      }
    }

    final inputController = StreamController<List<int>>();
    socket.listen(
      inputController.add,
      onError: (_) {
        inputController.close();
        cleanupClient();
      },
      onDone: () {
        inputController.close();
        cleanupClient();
      },
    );

    rpcSession = RpcSession(
      input: inputController.stream,
      output: (bytes) {
        try {
          socket.add(bytes);
        } catch (_) {}
      },
    );

    app = VibrainiumApp(
      nvim: Nvim(rpcSession),
      vcsList: vcsList,
      socketPath: socketPath,
      devPackagePath: devPackagePath,
      onShutdown: stop,
    );
    final origOnRequest = rpcSession.onRequest;
    rpcSession.onRequest = (method, params) async {
      if (method == 'vibrainium_agent_hook') {
        return dispatchAgentHook(params);
      }
      if (origOnRequest != null) {
        return origOnRequest(method, params);
      }
      return null;
    };
    final origOnNotification = rpcSession.onNotification;
    rpcSession.onNotification = (method, params) async {
      if (method == 'vibrainium_agent_hook') {
        await dispatchAgentHook(params);
        return;
      }
      if (origOnNotification != null) {
        origOnNotification(method, params);
      }
    };
    sessions.add(app);
  }

  void _scheduleIdleCheck() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () async {
      if (sessions.isEmpty) {
        await stop();
      }
    });
  }

  /// Broadcasts hot-reload UI updates to all connected Neovim instances.
  Future<void> broadcastHotReload() async {
    for (final app in sessions.toList()) {
      try {
        await app.onHotReloaded();
      } catch (_) {}
    }
  }

  /// Stops the daemon, closes all connections, and removes the socket file.
  Future<void> stop() async {
    _idleTimer?.cancel();
    _idleTimer = null;

    for (final s in _sockets.toList()) {
      try {
        s.destroy();
      } catch (_) {}
    }
    _sockets.clear();
    sessions.clear();

    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close();
      } catch (_) {}
    }

    if (parseTcpEndpoint(socketPath) == null) {
      try {
        final file = File(socketPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }
}
