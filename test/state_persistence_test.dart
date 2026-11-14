import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vibrainium/vibrainium.dart';

class _MockNvimServer {
  final StreamController<List<int>> _toClient = StreamController<List<int>>();
  final StreamController<List<int>> _fromClient = StreamController<List<int>>();
  late final RpcSession serverSession;
  late final RpcSession clientSession;

  String cwd;
  int fakePid;
  int _nextBuf = 1;
  int _nextWin = 100;
  final Map<int, List<String>> bufLines = {};
  final Map<int, String> bufNames = {};
  final Map<int, Map<String, Object?>> bufOptions = {};
  final Set<int> validWins = {1};
  final Map<int, int> winBufs = {1: 1};
  final Map<int, int> winWidths = {1: 80};
  final Map<int, int> winHeights = {1: 40};
  final Map<int, Map<String, Object?>> winConfigs = {};
  final List<String> commands = [];
  int currentWin = 1;

  Object? mockWinlayout = ['leaf', 1];

  _MockNvimServer({
    required this.cwd,
    this.fakePid = 54321,
  }) {
    bufLines[1] = ['void main() {}'];
    bufNames[1] = '$cwd/lib/main.dart';
    bufOptions[1] = {'filetype': 'dart', 'buftype': ''};

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

  Future<Object?> _handleRequest(String method, List<Object?> params) async {
    switch (method) {
      case 'nvim_create_namespace':
        return 1;
      case 'nvim_set_hl':
        return null;
      case 'nvim_create_buf':
        final id = ++_nextBuf;
        bufLines[id] = [];
        bufNames[id] = '';
        bufOptions[id] = {'filetype': '', 'buftype': ''};
        return MsgpackExt(0, MsgpackCodec.encode(id));
      case 'nvim_buf_is_valid':
        final b = params[0] as int;
        return bufLines.containsKey(b) || bufNames.containsKey(b);
      case 'nvim_buf_set_lines':
        final buf = params[0] as int;
        final lines = (params[4] as List).map((e) => e.toString()).toList();
        bufLines[buf] = lines;
        return null;
      case 'nvim_buf_clear_namespace':
        return null;
      case 'nvim_buf_set_extmark':
        return 1;
      case 'nvim_buf_set_keymap':
        return null;
      case 'nvim_buf_get_lines':
        final buf = params[0] as int;
        return bufLines[buf] ?? const <String>[];
      case 'nvim_set_option_value':
        final name = params[0].toString();
        final value = params[1];
        final opts = (params[2] as Map).cast<String, Object?>();
        if (opts.containsKey('buf')) {
          final buf = opts['buf'] as int;
          bufOptions.putIfAbsent(buf, () => {})[name] = value;
        }
        return null;
      case 'nvim_get_option_value':
        final name = params[0].toString();
        final opts = (params[1] as Map).cast<String, Object?>();
        if (opts.containsKey('buf')) {
          final buf = opts['buf'] as int;
          return bufOptions[buf]?[name] ?? '';
        }
        return null;
      case 'nvim_buf_get_name':
        final buf = params[0] as int;
        return bufNames[buf] ?? '';
      case 'nvim_buf_set_name':
        final buf = params[0] as int;
        bufNames[buf] = params[1].toString();
        return null;
      case 'nvim_get_current_buf':
        return winBufs[currentWin] ?? 1;
      case 'nvim_open_win':
        final buf = params[0] as int;
        final enter = params[1] as bool;
        final config = (params[2] as Map).cast<String, Object?>();
        final win = _nextWin++;
        validWins.add(win);
        winBufs[win] = buf;
        winConfigs[win] = config;
        if (config.containsKey('width')) {
          winWidths[win] = config['width'] as int;
        }
        if (enter) currentWin = win;
        return MsgpackExt(1, MsgpackCodec.encode(win));
      case 'nvim_win_is_valid':
        return validWins.contains(params[0] as int);
      case 'nvim_win_close':
        validWins.remove(params[0] as int);
        winBufs.remove(params[0] as int);
        return null;
      case 'nvim_win_set_buf':
        final win = params[0] as int;
        final buf = params[1] as int;
        winBufs[win] = buf;
        return null;
      case 'nvim_win_get_buf':
        return winBufs[params[0] as int] ?? 0;
      case 'nvim_win_get_config':
        return winConfigs[params[0] as int] ?? const {};
      case 'nvim_win_get_width':
        return winWidths[params[0] as int] ?? 80;
      case 'nvim_win_set_width':
        winWidths[params[0] as int] = params[1] as int;
        return null;
      case 'nvim_win_get_height':
        return winHeights[params[0] as int] ?? 40;
      case 'nvim_win_set_height':
        winHeights[params[0] as int] = params[1] as int;
        return null;
      case 'nvim_set_current_win':
        currentWin = params[0] as int;
        return null;
      case 'nvim_get_current_win':
        return currentWin;
      case 'nvim_list_wins':
        return validWins.toList();
      case 'nvim_win_get_cursor':
        return [1, 0];
      case 'nvim_win_set_cursor':
        return null;
      case 'nvim_command':
        commands.add(params[0].toString());
        return null;
      case 'nvim_exec_lua':
        final code = params[0].toString();
        if (code.contains('vim.fn.getpid')) {
          return fakePid;
        }
        if (code.contains('vim.fn.winlayout')) {
          return mockWinlayout;
        }
        if (code.contains('vim.fn.bufadd')) {
          final id = ++_nextBuf;
          final arg = (params.length > 1 && (params[1] as List).isNotEmpty)
              ? (params[1] as List).first.toString()
              : '';
          bufNames[id] = arg;
          bufLines[id] = [];
          bufOptions[id] = {'filetype': '', 'buftype': ''};
          return id;
        }
        return null;
      case 'nvim_call_function':
        if (params[0] == 'getcwd') return cwd;
        return null;
      default:
        return null;
    }
  }

  void close() {
    _toClient.close();
    _fromClient.close();
  }
}

void main() {
  group('State Persistence Integration', () {
    late Directory tempRoot;
    late Directory workspaceDir;
    late File testFileA;
    late File testFileB;
    late _MockNvimServer fakeServer;
    late VibrainiumApp app;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('vibr_persist_test_');
      workspaceDir = Directory('${tempRoot.path}/project');
      await workspaceDir.create(recursive: true);
      await Directory('${workspaceDir.path}/lib').create(recursive: true);
      testFileA = File('${workspaceDir.path}/lib/main.dart');
      await testFileA.writeAsString('void main() {}');
      testFileB = File('${workspaceDir.path}/lib/utils.dart');
      await testFileB.writeAsString('void helper() {}');

      fakeServer = _MockNvimServer(cwd: workspaceDir.path, fakePid: 54321);
      WorkspaceStateLock.customProcessChecker = (pid) => true;
      final nvim = Nvim(fakeServer.clientSession);
      app = VibrainiumApp(nvim: nvim);
    });

    tearDown(() async {
      WorkspaceStateLock.customProcessChecker = null;
      fakeServer.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('saveWorkspaceState writes state.json and acquires state.lock', () async {
      await app.openTab(VibrainiumTab.workspace);
      await app.saveWorkspaceState();

      final stateFile = File('${workspaceDir.path}/.vibrainium/state.json');
      expect(await stateFile.exists(), isTrue);

      final lock = WorkspaceStateLock.readLock(workspaceDir.path);
      expect(lock, isNotNull);
      expect(lock!.pid, 54321);

      final state = await VibrainiumWorkspaceState.load(workspaceDir.path);
      expect(state.version, 1);
      expect(state.explorer.isOpen, isTrue);
    });

    test('lock prevents secondary instance from overwriting state', () async {
      // Instance 1 holds the lock
      WorkspaceStateLock.tryAcquire(
        workspaceDir.path,
        54321,
        processChecker: (_) => true,
      );

      // Create a second server and app with a different pid 99999
      final fakeServer2 = _MockNvimServer(cwd: workspaceDir.path, fakePid: 99999);
      final nvim2 = Nvim(fakeServer2.clientSession);
      final app2 = VibrainiumApp(nvim: nvim2);

      // Mutate state.json directly
      final initial = const VibrainiumWorkspaceState(
        explorer: ExplorerState(width: 50),
      );
      await initial.saveAtomic(workspaceDir.path);

      // Instance 2 tries to save with width 30
      app2.workspaceSidebar.sidebarWidth = 30;
      await app2.saveWorkspaceState();

      // State on disk should still be width 50 because instance 2 was locked out
      final loaded = await VibrainiumWorkspaceState.load(workspaceDir.path);
      expect(loaded.explorer.width, 50);

      fakeServer2.close();
    });

    test('restoreWorkspaceState restores explorer and editor state', () async {
      final savedState = VibrainiumWorkspaceState(
        explorer: const ExplorerState(
          isOpen: true,
          width: 44,
          showHidden: true,
          expandedDirs: ['lib'],
        ),
        editor: EditorState(
          layout: EditorLeafNode(
            id: 'win-1',
            width: 80,
            height: 40,
            openFiles: ['lib/main.dart', 'lib/utils.dart'],
            activeFile: 'lib/main.dart',
          ),
        ),
      );
      await savedState.saveAtomic(workspaceDir.path);

      await app.restoreWorkspaceState();

      expect(app.workspaceSidebar.sidebarWidth, 44);
      expect(app.workspaceSidebar.treeState.showHidden, isTrue);
      expect(
        app.workspaceSidebar.treeState.isDirExpanded('${workspaceDir.path}/lib'),
        isTrue,
      );

      final viworkspaceWins = fakeServer.validWins.where((w) {
        final buf = fakeServer.winBufs[w];
        return fakeServer.bufOptions[buf]?['filetype'] == 'viworkspace';
      }).toList();
      expect(viworkspaceWins, hasLength(1));
    });

    test('workspace.save_state releases lock cleanly on exit', () async {
      await app.saveWorkspaceState();
      expect(WorkspaceStateLock.readLock(workspaceDir.path), isNotNull);

      // Trigger workspace.save_state RPC which flushes state and releases lock
      await app.nvim.rpc.onRequest!('workspace.save_state', []);

      final lock = WorkspaceStateLock.readLock(workspaceDir.path);
      expect(lock, isNull);
    });

    test('saveWorkspaceState never tracks panels as activePaneId when cursor is in a panel', () async {
      // Initially, cursor is in editor win 1 with lib/main.dart
      await app.editorTabbar.sync();
      expect(fakeServer.currentWin, 1);

      // Open workspace sidebar so panel windows exist and cursor enters the panel
      await app.openTab(VibrainiumTab.workspace);
      expect(app.mainWindowId, isNotNull);
      final sidebarWin = app.mainWindowId!;
      fakeServer.currentWin = sidebarWin;

      // Ensure that currentWin is indeed the sidebar panel window
      expect(fakeServer.currentWin, sidebarWin);

      await app.saveWorkspaceState();

      final state = await VibrainiumWorkspaceState.load(workspaceDir.path);
      // activePaneId must be editor win-1, NOT the sidebar panel window win-$sidebarWin
      expect(state.editor.activePaneId, 'win-1');
      expect(state.editor.activePaneId, isNot('win-$sidebarWin'));

      // Now open bottom problems panel and move cursor into it
      await app.openBottomTab(VibrainiumBottomTab.problems);
      final problemsWin = app.bottomMainWindowId!;
      fakeServer.currentWin = problemsWin;

      await app.saveWorkspaceState();

      final state2 = await VibrainiumWorkspaceState.load(workspaceDir.path);
      // activePaneId must still point to an editor window, never the problems panel window
      expect(state2.editor.activePaneId, 'win-1');
      expect(state2.editor.activePaneId, isNot('win-$problemsWin'));
    });

    test('exportLayout excludes panels and empty panes from editor layout', () async {
      // Set up editor win 1
      await app.editorTabbar.sync();

      // Open workspace sidebar (creates a panel window, e.g. 101)
      await app.openTab(VibrainiumTab.workspace);
      final sidebarWin = app.mainWindowId!;

      // Simulate a layout tree where sidebarWin is next to editor win 1
      fakeServer.mockWinlayout = [
        'row',
        [
          ['leaf', sidebarWin],
          ['leaf', 1],
        ],
      ];

      final layout = await app.editorTabbar.exportLayout(workspaceDir.path);
      // The panel window should be pruned, and the branch collapsed to the single editor leaf
      expect(layout, isNotNull);
      expect(layout, isA<EditorLeafNode>());
      final leaf = layout as EditorLeafNode;
      expect(leaf.id, 'win-1');
      expect(leaf.openFiles, contains('lib/main.dart'));
    });

    test('exportPaneForWindow returns null for panel filetypes and panes with no files', () async {
      // 1. Window with a panel filetype (e.g. viagent-term)
      final panelWin = 200;
      final panelBuf = 200;
      fakeServer.validWins.add(panelWin);
      fakeServer.winBufs[panelWin] = panelBuf;
      fakeServer.bufOptions[panelBuf] = {'filetype': 'viagent-term', 'buftype': 'nofile'};
      fakeServer.bufNames[panelBuf] = 'terminal';

      final panelPane = await app.editorTabbar.exportPaneForWindow(panelWin, workspaceDir.path);
      expect(panelPane, isNull);

      // 2. Window with empty trackable files
      final emptyWin = 201;
      final emptyBuf = 201;
      fakeServer.validWins.add(emptyWin);
      fakeServer.winBufs[emptyWin] = emptyBuf;
      fakeServer.bufOptions[emptyBuf] = {'filetype': '', 'buftype': ''};
      fakeServer.bufNames[emptyBuf] = ''; // No name

      final emptyPane = await app.editorTabbar.exportPaneForWindow(emptyWin, workspaceDir.path);
      expect(emptyPane, isNull);
    });
  });
}
