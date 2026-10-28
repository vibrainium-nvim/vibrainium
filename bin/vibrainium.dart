import 'dart:async';
import 'dart:io';

import 'package:vibrainium/vibrainium.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    final sub = args.first;
    if (sub == 'install') {
      String? devPath;
      final devIdx = args.indexOf('--dev');
      if (devIdx != -1) {
        if (devIdx + 1 >= args.length) {
          stderr.writeln('Error: --dev requires a <path> argument.');
          exitCode = 64;
          return;
        }
        devPath = args[devIdx + 1];
      }
      try {
        final installedPath = await VibrainiumInstaller.install(devPath: devPath);
        if (devPath != null) {
          stdout.writeln('Installed vibrainium (dev mode -> $devPath) at $installedPath');
        } else {
          stdout.writeln('Installed vibrainium (system PATH mode) at $installedPath');
        }
      } catch (e) {
        stderr.writeln('Failed to install vibrainium: $e');
        exitCode = 1;
      }
      return;
    } else if (sub == 'uninstall') {
      final removed = await VibrainiumInstaller.uninstall();
      if (removed) {
        stdout.writeln('Uninstalled vibrainium from Neovim.');
      } else {
        stdout.writeln('vibrainium is not currently installed.');
      }
      return;
    } else if (sub == '--help' || sub == '-h' || sub == 'help') {
      stdout.writeln('Usage:');
      stdout.writeln('  vibrainium install               Install vibrainium plugin (uses vibrainium from system PATH)');
      stdout.writeln('  vibrainium install --dev <path>  Install vibrainium plugin in dev mode using dart run from <path>');
      stdout.writeln('  vibrainium uninstall             Uninstall vibrainium plugin from Neovim');
      stdout.writeln('  vibrainium daemon [--socket <p>] Run multi-Neovim shared RPC daemon');
      return;
    } else if (sub == 'daemon') {
      String? devPkgPath;
      final devIdx = args.indexOf('--dev');
      if (devIdx != -1 && devIdx + 1 < args.length) {
        devPkgPath = args[devIdx + 1];
      }

      String? socketPath;
      final sockIdx = args.indexOf('--socket');
      if (sockIdx != -1 && sockIdx + 1 < args.length) {
        socketPath = args[sockIdx + 1];
      }
      socketPath ??= VibrainiumDaemon.defaultSocketPath(
        devPackagePath: devPkgPath,
      );

      final daemon = VibrainiumDaemon(socketPath: socketPath);
      final started = await daemon.start();
      if (!started) {
        return;
      }

      final watched = <StreamSubscription<FileSystemEvent>>[];
      if (devPkgPath != null) {
        final monorepoRoot = Directory(devPkgPath).parent.path;
        watched.addAll(
          HotReloader.watchDirs(
            [
              '$devPkgPath/lib',
              '$monorepoRoot/vivcs/lib',
              '$monorepoRoot/viworkspace/lib',
              '$monorepoRoot/nvim/lib',
            ],
            onReloaded: daemon.broadcastHotReload,
          ),
        );
      }

      await daemon.done;
      for (final subWatch in watched) {
        await subWatch.cancel();
      }
      return;
    }
  }

  // Default: Run as stdio msgpack-rpc server for Neovim
  String? devPkgPath;
  final devIdx = args.indexOf('--dev');
  if (devIdx != -1 && devIdx + 1 < args.length) {
    devPkgPath = args[devIdx + 1];
  }

  final completer = Completer<void>();
  final inputController = StreamController<List<int>>();
  stdin.listen(
    inputController.add,
    onError: (_) {},
    onDone: () {
      inputController.close();
      if (!completer.isCompleted) {
        completer.complete();
      }
    },
  );

  final session = RpcSession(
    input: inputController.stream,
    output: (bytes) {
      stdout.add(bytes);
    },
  );

  final app = VibrainiumApp(nvim: Nvim(session));

  final watched = <StreamSubscription<FileSystemEvent>>[];
  if (devPkgPath != null) {
    final monorepoRoot = Directory(devPkgPath).parent.path;
    watched.addAll(
      HotReloader.watchDirs(
        [
          '$devPkgPath/lib',
          '$monorepoRoot/visettings/lib',
          '$monorepoRoot/vivcs/lib',
          '$monorepoRoot/viworkspace/lib',
          '$monorepoRoot/nvim/lib',
        ],
        onReloaded: app.onHotReloaded,
      ),
    );
  }

  await completer.future;
  for (final sub in watched) {
    await sub.cancel();
  }
}
