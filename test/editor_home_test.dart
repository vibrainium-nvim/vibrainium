import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vibrainium/vibrainium.dart';

class _HomeMockNvimServer {
  final StreamController<List<int>> _toClient = StreamController<List<int>>();
  final StreamController<List<int>> _fromClient = StreamController<List<int>>();
  late final RpcSession serverSession;
  late final RpcSession clientSession;

  String cwd = '/workspace';
  int _nextBuf = 10;
  int _nextWin = 10;
  int currentWin = 1;

  final Set<int> validWins = {1};
  final Map<int, int> winBufs = {1: 1};
  final Map<int, int> winWidths = {1: 100};
  final Map<int, (int, int)> winCursors = {1: (1, 0)};
  final Map<int, Map<String, Object?>> winConfigs = {};
  final Map<int, Map<String, Object?>> winOptions = {};

  final Set<int> validBufs = {1};
  final Map<int, List<String>> bufLines = {
    1: ['void main() {}'],
  };
  final Map<int, String> bufNames = {
    1: '/workspace/lib/main.dart',
  };
  final Map<int, Map<String, Object?>> bufOptions = {
    1: {'filetype': 'dart', 'buftype': '', 'modified': false},
  };
  final List<String> commands = [];
  final List<int> deletedBufs = [];
  List<String> oldFiles = [];
  bool hasLsp = false;

  _HomeMockNvimServer() {
    serverSession = RpcSession(
      input: _fromClient.stream,
      output: (Uint8List b) => _toClient.add(b),
    );
    clientSession = RpcSession(
      input: _toClient.stream,
      output: (Uint8List b) => _fromClient.add(b),
    );
    serverSession.onRequest = _handleRequest;
  }

  int addFileBuffer(String path, {String filetype = 'dart'}) {
    final id = ++_nextBuf;
    validBufs.add(id);
    bufLines[id] = ['// $path'];
    bufNames[id] = path;
    bufOptions[id] = {'filetype': filetype, 'buftype': '', 'modified': false};
    return id;
  }

  int addSplitWindow(int bufId) {
    final win = ++_nextWin;
    validWins.add(win);
    winBufs[win] = bufId;
    winWidths[win] = 80;
    winCursors[win] = (1, 0);
    return win;
  }

  Future<Object?> _handleRequest(String method, List<Object?> params) async {
    switch (method) {
      case 'nvim_create_namespace':
        return 1;
      case 'nvim_set_hl':
        return null;
      case 'nvim_create_buf':
        final id = ++_nextBuf;
        validBufs.add(id);
        bufLines[id] = [];
        bufNames[id] = '';
        bufOptions[id] = {'filetype': '', 'buftype': '', 'modified': false};
        return id;
      case 'nvim_buf_is_valid':
        return validBufs.contains(params[0] as int);
      case 'nvim_buf_set_lines':
        final buf = params[0] as int;
        final lines = (params[4] as List).cast<String>();
        bufLines[buf] = List<String>.from(lines);
        return null;
      case 'nvim_buf_get_lines':
        final buf = params[0] as int;
        return bufLines[buf] ?? <String>[];
      case 'nvim_buf_set_option':
        final buf = params[0] as int;
        final name = params[1] as String;
        bufOptions.putIfAbsent(buf, () => {})[name] = params[2];
        return null;
      case 'nvim_buf_get_option':
        final buf = params[0] as int;
        final name = params[1] as String;
        return bufOptions[buf]?[name];
      case 'nvim_buf_get_name':
        return bufNames[params[0] as int] ?? '';
      case 'nvim_buf_set_keymap':
      case 'nvim_buf_clear_namespace':
      case 'nvim_buf_set_extmark':
        return 1;
      case 'nvim_list_wins':
        return validWins.toList();
      case 'nvim_win_is_valid':
        return validWins.contains(params[0] as int);
      case 'nvim_win_get_config':
        return winConfigs[params[0] as int] ?? <String, Object?>{};
      case 'nvim_win_get_buf':
        return winBufs[params[0] as int] ?? 0;
      case 'nvim_win_set_buf':
        final win = params[0] as int;
        final newBuf = params[1] as int;
        final oldBuf = winBufs[win];
        winBufs[win] = newBuf;
        if (oldBuf != null &&
            oldBuf != newBuf &&
            bufOptions[oldBuf]?['bufhidden'] == 'wipe' &&
            !winBufs.values.contains(oldBuf)) {
          validBufs.remove(oldBuf);
          deletedBufs.add(oldBuf);
        }
        return null;
      case 'nvim_win_close':
        final win = params[0] as int;
        validWins.remove(win);
        winBufs.remove(win);
        if (currentWin == win && validWins.isNotEmpty) {
          currentWin = validWins.first;
        }
        return null;
      case 'nvim_win_get_width':
        return winWidths[params[0] as int] ?? 80;
      case 'nvim_win_set_cursor':
        final win = params[0] as int;
        final pos = params[1] as List;
        winCursors[win] = (pos[0] as int, pos[1] as int);
        return null;
      case 'nvim_win_get_cursor':
        final pos = winCursors[params[0] as int] ?? (1, 0);
        return [pos.$1, pos.$2];
      case 'nvim_get_current_win':
        return currentWin;
      case 'nvim_set_current_win':
        currentWin = params[0] as int;
        return null;
      case 'nvim_set_option_value':
        final name = params[0] as String;
        final value = params[1];
        final opts = params[2] as Map?;
        final buf = opts?['buf'] as int?;
        final win = opts?['win'] as int?;
        if (buf != null) {
          bufOptions.putIfAbsent(buf, () => {})[name] = value;
        } else if (win != null) {
          winOptions.putIfAbsent(win, () => {})[name] = value;
        }
        return null;
      case 'nvim_get_option_value':
        final name = params[0] as String;
        final opts = params[1] as Map?;
        final buf = opts?['buf'] as int?;
        final win = opts?['win'] as int?;
        if (buf != null) {
          return bufOptions[buf]?[name];
        }
        if (win != null) {
          return winOptions[win]?[name] ?? '';
        }
        return '';
      case 'nvim_win_set_option':
        final win = params[0] as int;
        final name = params[1] as String;
        winOptions.putIfAbsent(win, () => {})[name] = params[2];
        return null;
      case 'nvim_command':
        commands.add(params[0] as String);
        return null;
      case 'nvim_exec_lua':
        final code = params[0] as String;
        if (code.contains('vim.v.oldfiles')) {
          return oldFiles;
        }
        if (code.contains('vim.lsp.get_clients')) {
          return hasLsp;
        }
        if (code.contains('nvim_buf_delete')) {
          final args = params[1] as List;
          final buf = args[0] as int;
          validBufs.remove(buf);
          deletedBufs.add(buf);
          return null;
        }
        if (code.contains('nvim_win_layout') || code.contains('winlayout')) {
          return ['leaf', validWins.first];
        }
        return null;
      default:
        return null;
    }
  }

  Future<void> dispose() async {
    await _toClient.close();
    await _fromClient.close();
  }
}

void main() {
  group('EditorHomeView & EditorTabbar empty-pane behavior', () {
    test('closing last tab of the only editor pane shows vibrainium-home with recent files', () async {
      final server = _HomeMockNvimServer();
      final nvim = Nvim(server.clientSession);
      final home = EditorHomeView(
        nvim: nvim,
        getWorkspaceRoot: () async => '/workspace',
        fileExists: (_) => true,
      );
      final tabbar = EditorTabbar(
        nvim: nvim,
        nonEditorFiletypes: const {},
        isPanelWin: (_) => false,
        onShowEmptyHome: (win) => home.showInWindow(win),
        onTabClosedPath: (path) => home.recordRecentFile(path),
        onSync: () => home.cleanupIfHidden(),
      );

      await tabbar.sync();
      expect(tabbar.tabsForWindow(1), [1]);

      await tabbar.closeTab(winId: 1, bufId: 1);

      expect(server.validWins, contains(1));
      expect(tabbar.tabsForWindow(1), isEmpty);

      final homeBuf = server.winBufs[1]!;
      expect(homeBuf, equals(home.bufId));
      expect(server.bufOptions[homeBuf]?['filetype'], EditorHomeView.homeFiletype);
      expect(server.bufOptions[homeBuf]?['buftype'], 'nofile');
      expect(server.bufOptions[homeBuf]?['bufhidden'], 'wipe');
      expect(server.bufOptions[homeBuf]?['buflisted'], false);
      expect(server.bufOptions[homeBuf]?['modifiable'], false);

      final lines = server.bufLines[homeBuf]!;
      expect(lines.any((l) => l.contains('Find File')), isTrue);
      expect(lines.any((l) => l.contains('Search Text')), isTrue);
      expect(lines.any((l) => l.contains('Workspace Symbols')), isTrue);
      expect(lines.any((l) => l.contains('lib/main.dart')), isTrue);

      final layout = await tabbar.exportLayout('/workspace');
      expect(layout, isNull);

      await server.dispose();
    });

    test('closing last tab in one of two splits closes that split instead of showing home', () async {
      final server = _HomeMockNvimServer();
      final nvim = Nvim(server.clientSession);
      final home = EditorHomeView(
        nvim: nvim,
        getWorkspaceRoot: () async => '/workspace',
        fileExists: (_) => true,
      );
      final tabbar = EditorTabbar(
        nvim: nvim,
        nonEditorFiletypes: const {},
        isPanelWin: (_) => false,
        onShowEmptyHome: (win) => home.showInWindow(win),
        onTabClosedPath: (path) => home.recordRecentFile(path),
        onSync: () => home.cleanupIfHidden(),
      );

      final buf2 = server.addFileBuffer('/workspace/lib/other.dart');
      final win2 = server.addSplitWindow(buf2);
      server.currentWin = win2;

      await tabbar.sync();
      expect(tabbar.tabsForWindow(1), [1]);
      expect(tabbar.tabsForWindow(win2), [buf2]);

      await tabbar.closeTab(winId: win2, bufId: buf2);

      expect(server.validWins.contains(win2), isFalse);
      expect(server.validWins, [1]);
      expect(server.currentWin, 1);
      expect(home.bufId, isNull);

      await server.dispose();
    });

    test('opening a real file replaces and wipes the dummy home buffer', () async {
      final server = _HomeMockNvimServer();
      final nvim = Nvim(server.clientSession);
      final home = EditorHomeView(
        nvim: nvim,
        getWorkspaceRoot: () async => '/workspace',
        fileExists: (_) => true,
      );
      final tabbar = EditorTabbar(
        nvim: nvim,
        nonEditorFiletypes: const {},
        isPanelWin: (_) => false,
        onShowEmptyHome: (win) => home.showInWindow(win),
        onTabClosedPath: (path) => home.recordRecentFile(path),
        onSync: () => home.cleanupIfHidden(),
      );

      await tabbar.sync();
      await tabbar.closeAllTabs(winId: 1);

      final homeBuf = home.bufId!;
      expect(server.validBufs.contains(homeBuf), isTrue);

      final newFileBuf = server.addFileBuffer('/workspace/lib/opened.dart');
      await nvim.winSetBuf(1, newFileBuf);
      await tabbar.sync();

      expect(home.bufId, isNull);
      expect(server.validBufs.contains(homeBuf), isFalse);
      expect(tabbar.tabsForWindow(1), [newFileBuf]);

      await server.dispose();
    });

    test('home.activate opens recent file or triggers search action based on cursor line', () async {
      final server = _HomeMockNvimServer();
      server.oldFiles = ['/workspace/lib/old_one.dart'];
      final nvim = Nvim(server.clientSession);
      final home = EditorHomeView(
        nvim: nvim,
        getWorkspaceRoot: () async => '/workspace',
        fileExists: (_) => true,
      );

      await home.showInWindow(1);

      String? openedFile;
      int? openedWin;
      String? triggeredSearch;

      // Cursor starts on the first entry (Find File quick action).
      await home.handleAction(
        'home.activate',
        onOpenFile: (path, win) async {
          openedFile = path;
          openedWin = win;
        },
        onTriggerSearch: (action) async {
          triggeredSearch = action;
        },
      );
      expect(triggeredSearch, 'search.files');
      expect(openedFile, isNull);

      // Move cursor to the recent file entry and activate.
      final fileEntry = home.entries.firstWhere((e) => e.filePath != null);
      await nvim.winSetCursor(1, fileEntry.line1Based, 4);
      await home.handleAction(
        'home.activate',
        onOpenFile: (path, win) async {
          openedFile = path;
          openedWin = win;
        },
        onTriggerSearch: (action) async {
          triggeredSearch = action;
        },
      );
      expect(openedFile, '/workspace/lib/old_one.dart');
      expect(openedWin, 1);

      await server.dispose();
    });

    test('renders unchecked-in files ordered by modified date (recent first) and opens on activate', () async {
      final server = _HomeMockNvimServer();
      final nvim = Nvim(server.clientSession);
      final mtimes = <String, DateTime>{
        '/workspace/lib/older.dart': DateTime(2026, 1, 1, 10, 0),
        '/workspace/lib/newest.dart': DateTime(2026, 1, 3, 12, 0),
        '/workspace/lib/middle.dart': DateTime(2026, 1, 2, 11, 0),
      };
      final home = EditorHomeView(
        nvim: nvim,
        getWorkspaceRoot: () async => '/workspace',
        getUncheckedInFiles: (_) async => const [
          EditorHomeVcsFile(path: '/workspace/lib/older.dart', statusCode: 'M'),
          EditorHomeVcsFile(path: '/workspace/lib/removed.dart', statusCode: 'D'),
          EditorHomeVcsFile(path: '/workspace/lib/newest.dart', statusCode: '?'),
          EditorHomeVcsFile(path: '/workspace/lib/middle.dart', statusCode: 'A'),
        ],
        fileModifiedAt: (p) => mtimes[p],
        fileExists: (_) => true,
      );

      final buf = await home.showInWindow(1);
      final lines = server.bufLines[buf]!;

      expect(lines.any((l) => l.contains('Unchecked-in Files')), isTrue);
      expect(lines.any((l) => l.contains('Recently Changed Files')), isFalse);

      final newestIdx = lines.indexWhere((l) => l.contains('[?] lib/newest.dart'));
      final middleIdx = lines.indexWhere((l) => l.contains('[A] lib/middle.dart'));
      final olderIdx = lines.indexWhere((l) => l.contains('[M] lib/older.dart'));
      final removedIdx = lines.indexWhere((l) => l.contains('[D] lib/removed.dart'));

      expect(newestIdx, greaterThan(0));
      expect(middleIdx, greaterThan(newestIdx));
      expect(olderIdx, greaterThan(middleIdx));
      expect(removedIdx, greaterThan(olderIdx));

      // Deleted file should not be an openable entry.
      expect(
        home.entries.any((e) => e.filePath == '/workspace/lib/removed.dart'),
        isFalse,
      );

      final newestEntry = home.entries
          .firstWhere((e) => e.filePath == '/workspace/lib/newest.dart');

      String? openedFile;
      await nvim.winSetCursor(1, newestEntry.line1Based, 4);
      await home.handleAction(
        'home.activate',
        onOpenFile: (path, _) async => openedFile = path,
        onTriggerSearch: (_) async {},
      );
      expect(openedFile, '/workspace/lib/newest.dart');

      await server.dispose();
    });

    test('renders empty-state label when working tree is clean', () async {
      final server = _HomeMockNvimServer();
      final nvim = Nvim(server.clientSession);
      final home = EditorHomeView(
        nvim: nvim,
        getWorkspaceRoot: () async => '/workspace',
        getUncheckedInFiles: (_) async => const [],
        fileExists: (_) => true,
      );

      final buf = await home.showInWindow(1);
      final lines = server.bufLines[buf]!;

      expect(lines.any((l) => l.contains('(clean working tree)')), isTrue);
      expect(lines.any((l) => l.contains('Recently Changed Files')), isFalse);

      await server.dispose();
    });
  });
}
