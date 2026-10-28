import 'dart:async';
import 'dart:io';

import 'package:vivcs/vivcs.dart';

import 'app.dart';

/// Multi-client Unix domain socket daemon that manages multiple Neovim instances.
class VibrainiumDaemon {
  final String socketPath;
  final Duration idleTimeout;
  final List<Vcs> vcsList;

  ServerSocket? _server;
  final Set<VibrainiumApp> sessions = {};
  final Set<Socket> _sockets = {};
  Timer? _idleTimer;
  final Completer<void> _doneCompleter = Completer<void>();

  VibrainiumDaemon({
    required this.socketPath,
    this.idleTimeout = const Duration(seconds: 2),
    this.vcsList = const [Git(), Svn()],
  });

  /// Completes when the daemon stops.
  Future<void> get done => _doneCompleter.future;

  /// Computes a deterministic Unix domain socket path (< 100 chars for macOS SUN_LEN limit).
  static String defaultSocketPath({String? devPackagePath}) {
    final user = Platform.environment['USER'] ??
        Platform.environment['USERNAME'] ??
        'default';
    if (devPackagePath == null) {
      return '/tmp/vibrainium-$user-prod.sock';
    }
    var hash = 5381;
    for (final unit in devPackagePath.codeUnits) {
      hash = ((hash << 5) + hash) ^ unit;
    }
    final hex = (hash & 0xffffffff).toRadixString(16).padLeft(8, '0');
    return '/tmp/vibrainium-$user-dev-$hex.sock';
  }

  /// Returns true if an existing `vibrainium` daemon is actively listening on [socketPath].
  static Future<bool> isSocketAlive(String socketPath) async {
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

  /// Starts listening on [socketPath].
  /// Returns `false` if another daemon is already listening on [socketPath].
  Future<bool> start() async {
    if (await isSocketAlive(socketPath)) {
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
      return false;
    }

    final existingType = await FileSystemEntity.type(socketPath, followLinks: false);
    if (existingType != FileSystemEntityType.notFound) {
      try {
        await File(socketPath).delete();
      } catch (_) {}
    }

    final server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
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
      onShutdown: stop,
    );
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

    try {
      final file = File(socketPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }
}
