import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:vibrainium/vibrainium.dart';

class _FakeNvimServer {
  final StreamController<List<int>> _toClient = StreamController<List<int>>();
  final StreamController<List<int>> _fromClient = StreamController<List<int>>();
  late final RpcSession serverSession;
  late final RpcSession clientSession;

  String cwd;
  int _nextBuf = 1;
  int _nextWin = 100;
  final Map<int, List<String>> bufLines = {};
  final Map<int, String> bufNames = {};
  final Map<int, Map<String, Object?>> bufOptions = {};
  final Map<int, Map<String, Object?>> bufVars = {};
  final Map<int, Map<String, String>> bufKeymaps = {};
  final Map<int, List<Map<String, Object?>>> bufExtmarks = {};
  final Set<int> validWins = {1};
  final Map<int, int> winBufs = {1: 0};
  final Map<int, int> winWidths = {};
  final Map<int, Map<String, Object?>> winConfigs = {};
  final Map<int, Map<String, Object?>> winOptions = {};
  final Map<String, Object?> globalOptions = {};
  final Map<int, (int, int)> cursors = {1: (1, 0)};
  final List<String> notifications = [];
  final List<String> commands = [];
  final Map<String, String> registers = {};
  final List<String> chanSent = [];
  List<Map<String, Object?>> rawDiagnostics = [];
  int currentWin = 1;
  int? alternateWin;
  Map<String, Object?>? mousePos;

  _FakeNvimServer({required this.cwd}) {
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
        while (bufLines.containsKey(_nextBuf) || bufNames.containsKey(_nextBuf)) {
          _nextBuf++;
        }
        final id = _nextBuf++;
        bufLines[id] = [];
        bufNames[id] = '';
        bufKeymaps[id] = {};
        bufExtmarks[id] = [];
        return MsgpackExt(0, MsgpackCodec.encode(id));
      case 'nvim_buf_is_valid':
        return bufLines.containsKey(params[0] as int);
      case 'nvim_buf_set_lines':
        final buf = params[0] as int;
        final lines = (params[4] as List).map((e) => e.toString()).toList();
        bufLines[buf] = lines;
        return null;
      case 'nvim_buf_get_lines':
        final buf = params[0] as int;
        return bufLines[buf] ?? const <String>[];
      case 'nvim_set_option_value':
        final name = params[0].toString();
        final value = params[1];
        final opts = (params[2] as Map).cast<String, Object?>();
        if (opts.containsKey('win')) {
          final win = opts['win'] as int;
          winOptions.putIfAbsent(win, () => {})[name] = value;
        } else if (opts.containsKey('buf')) {
          final buf = opts['buf'] as int;
          bufOptions.putIfAbsent(buf, () => {})[name] = value;
        } else {
          globalOptions[name] = value;
        }
        return null;
      case 'nvim_buf_set_var':
        final buf = params[0] as int;
        bufVars.putIfAbsent(buf, () => {})[params[1].toString()] = params[2];
        return null;
      case 'nvim_buf_set_keymap':
        final buf = params[0] as int;
        final lhs = params[2].toString();
        final rhs = params[3].toString();
        bufKeymaps.putIfAbsent(buf, () => {})[lhs] = rhs;
        return null;
      case 'nvim_buf_clear_namespace':
        final buf = params[0] as int;
        bufExtmarks[buf] = [];
        return null;
      case 'nvim_buf_set_extmark':
        final buf = params[0] as int;
        final line = params[2] as int;
        final col = params[3] as int;
        final opts = (params[4] as Map).cast<String, Object?>();
        bufExtmarks.putIfAbsent(buf, () => []).add({
          'line': line,
          'col': col,
          ...opts,
        });
        return 1;
      case 'nvim_open_win':
        final buf = params[0] as int;
        final enter = params[1] as bool;
        final config = (params[2] as Map).cast<String, Object?>();
        final win = _nextWin++;
        validWins.add(win);
        winBufs[win] = buf;
        winConfigs[win] = config;
        cursors[win] = (1, 0);
        if (enter) {
          currentWin = win;
        }
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
      case 'nvim_win_set_config':
        final win = params[0] as int;
        final config = (params[1] as Map).cast<String, Object?>();
        winConfigs[win] = config;
        return null;
      case 'nvim_get_current_buf':
        return winBufs[currentWin] ?? 1;
      case 'nvim_buf_get_name':
        final buf = params[0] as int;
        return bufNames[buf] ?? '$cwd/hello.dart';
      case 'nvim_buf_set_name':
        final buf = params[0] as int;
        bufNames[buf] = params[1].toString();
        return null;
      case 'nvim_exec_lua':
        final code = params[0].toString();
        if (code.contains('vim.diagnostic.get')) {
          return rawDiagnostics;
        }
        return null;
      case 'nvim_win_get_buf':
        return winBufs[params[0] as int] ?? 0;
      case 'nvim_win_get_width':
        final win = params[0] as int;
        return winWidths[win] ?? 80;
      case 'nvim_win_get_cursor':
        final win = params[0] as int;
        final c = cursors[win] ?? (1, 0);
        return [c.$1, c.$2];
      case 'nvim_win_set_cursor':
        final win = params[0] as int;
        final pos = params[1] as List;
        cursors[win] = (pos[0] as int, pos[1] as int);
        return null;
      case 'nvim_set_current_win':
        currentWin = params[0] as int;
        return null;
      case 'nvim_get_current_win':
        return currentWin;
      case 'nvim_list_wins':
        return validWins.toList();
      case 'nvim_call_function':
        if (params[0] == 'getcwd') return cwd;
        if (params[0] == 'winnr') return alternateWin != null ? 1 : 0;
        if (params[0] == 'win_getid') return alternateWin ?? 0;
        if (params[0] == 'getmousepos') return mousePos;
        if (params[0] == 'setreg') {
          final args = params[1] as List;
          registers[args[0].toString()] = args[1].toString();
          return 0;
        }
        if (params[0] == 'jobstart') {
          return 42;
        }
        if (params[0] == 'chansend') {
          final args = params[1] as List;
          chanSent.add(args[1].toString());
          return 1;
        }
        return null;
      case 'nvim_get_option_value':
        final name = params[0].toString();
        final opts = params.length > 1 && params[1] is Map
            ? (params[1] as Map).cast<String, Object?>()
            : const <String, Object?>{};
        if (opts.containsKey('buf')) {
          final buf = opts['buf'] as int;
          return bufOptions[buf]?[name] ?? '';
        }
        if (opts.containsKey('win')) {
          final win = opts['win'] as int;
          return winOptions[win]?[name];
        }
        if (name == 'columns') return 120;
        if (name == 'lines') return 40;
        return globalOptions[name];
      case 'nvim_notify':
        notifications.add(params[0].toString());
        return null;
      case 'nvim_command':
        commands.add(params[0].toString());
        return null;
      default:
        return null;
    }
  }

  Future<void> dispose() async {
    await clientSession.close();
    await serverSession.close();
    await _toClient.close();
    await _fromClient.close();
  }
}

void main() {
  group('VibrainiumApp', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('vibrainium_app_test_');
      await File('${tempDir.path}/hello.dart').writeAsString('void main() {}');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('routes vibrainium_action RPC calls to vcsSidebar and workspaceSidebar', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      final app = VibrainiumApp(nvim: Nvim(server.clientSession), vcsList: const []);
      expect(app.vcsSidebar.repos, isEmpty);
      expect(app.workspaceSidebar.rootPath, isNull);

      final res = await server.serverSession.request('vibrainium_action', ['repo_picker']);
      expect(res, isTrue);
      expect(server.notifications, contains('No repositories discovered in workspace'));

      final wsRes = await server.serverSession.request(
        'vibrainium_action',
        ['workspace.close'],
      );
      expect(wsRes, isTrue);

      final searchRes = await server.serverSession.request(
        'vibrainium_action',
        ['search.files'],
      );
      expect(searchRes, isTrue);
      expect(await app.searchPicker.isOpen(), isTrue);

      await server.serverSession.request(
        'vibrainium_action',
        ['search.close'],
      );
      expect(await app.searchPicker.isOpen(), isFalse);

      await server.dispose();
    });

    test('opens unified sidepanel with 1-line bottom tabbar split and switches tabs in-place', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      final app = VibrainiumApp(nvim: Nvim(server.clientSession), vcsList: const []);

      // 1. Open Explorer tab (`workspace.open`)
      await server.serverSession.request('vibrainium_action', ['workspace.open']);
      expect(await app.isOpen(), isTrue);
      expect(app.activeTab, VibrainiumTab.workspace);

      final mainWin = app.mainWindowId!;
      final tabbarWin = app.tabbarWindowId!;
      final tabbarBuf = app.tabbarBufferId!;
      final wsBuf = app.workspaceSidebar.bufferId!;

      expect(server.winBufs[mainWin], wsBuf);
      expect(server.winConfigs[mainWin]!['win'], -1);
      expect(server.winConfigs[mainWin]!['split'], 'left');
      expect(server.winConfigs[mainWin]!['style'], 'minimal');
      expect(server.winOptions[mainWin]!['number'], isFalse);
      expect(server.winOptions[mainWin]!['relativenumber'], isFalse);
      expect(server.winOptions[mainWin]!['signcolumn'], 'no');
      expect(server.winOptions[mainWin]!['foldcolumn'], '0');
      expect(server.winOptions[mainWin]!['statuscolumn'], '');
      expect(server.winConfigs[tabbarWin]!['win'], mainWin);
      expect(server.winConfigs[tabbarWin]!['split'], 'below');
      expect(server.winConfigs[tabbarWin]!['height'], 1);
      expect(server.winConfigs[tabbarWin]!['style'], 'minimal');
      expect(server.winOptions[tabbarWin]!['number'], isFalse);
      expect(server.winOptions[tabbarWin]!['relativenumber'], isFalse);
      expect(server.winOptions[tabbarWin]!['signcolumn'], 'no');
      expect(server.winOptions[tabbarWin]!['foldcolumn'], '0');
      expect(server.winOptions[tabbarWin]!['statuscolumn'], '');
      expect(server.winConfigs[tabbarWin]!.containsKey('focusable'), isFalse);

      // Tabbar line contains Explorer [1] and VCS [2]
      expect(server.bufLines[tabbarBuf]!.single, contains('Explorer [1]'));
      expect(server.bufLines[tabbarBuf]!.single, contains('VCS [2]'));
      expect(
        server.bufKeymaps[tabbarBuf]!.keys,
        containsAll([
          '<LeftMouse>',
          '<LeftRelease>',
          '<CR>',
          'q',
          'H',
          '<Tab>',
          '<S-Tab>',
          '1',
          '2',
        ]),
      );
      expect(
        server.bufKeymaps[tabbarBuf]!['<LeftMouse>'],
        "<LeftMouse><Cmd>lua require('vibrainium').action('tab.click')<CR>",
      );
      expect(
        server.bufKeymaps[tabbarBuf]!['<LeftRelease>'],
        "<LeftRelease><Cmd>lua require('vibrainium').action('tab.click')<CR>",
      );

      // Active highlight is on Explorer (first extmark), Inactive on VCS (third extmark)
      final wsTabMarks = server.bufExtmarks[tabbarBuf]!;
      expect(wsTabMarks[0]['hl_group'], 'VibrainiumTabActive');
      expect(wsTabMarks[1]['hl_group'], 'VibrainiumTabSeparator');
      expect(wsTabMarks[2]['hl_group'], 'VibrainiumTabInactive');

      // Tab-switching keymaps are bound in workspace buffer
      expect(server.bufKeymaps[wsBuf]!.keys, containsAll(['<Tab>', '<S-Tab>', '1', '2']));

      // 2. Switch to VCS tab via `toggle` while Explorer is active -> switches tab without creating new windows
      await server.serverSession.request('vibrainium_action', ['toggle']);
      expect(await app.isOpen(), isTrue);
      expect(app.activeTab, VibrainiumTab.vcs);
      expect(app.mainWindowId, mainWin);
      expect(app.tabbarWindowId, tabbarWin);

      final vcsBuf = app.vcsSidebar.bufferId!;
      expect(server.winBufs[mainWin], vcsBuf);

      final vcsTabMarks = server.bufExtmarks[tabbarBuf]!;
      expect(vcsTabMarks[0]['hl_group'], 'VibrainiumTabInactive');
      expect(vcsTabMarks[2]['hl_group'], 'VibrainiumTabActive');

      // 3. Cycle back to Explorer via `tab.next`
      await server.serverSession.request('vibrainium_action', ['tab.next']);
      expect(app.activeTab, VibrainiumTab.workspace);
      expect(server.winBufs[mainWin], wsBuf);

      // 4. Opening a file from Explorer focuses editor window (1), NOT mainWin or tabbarWin
      server.cursors[mainWin] = (2, 0); // row 2 is `hello.dart`
      await server.serverSession.request('vibrainium_action', ['workspace.enter']);
      expect(server.currentWin, 1);
      expect(server.commands.any((c) => c.endsWith('/hello.dart')), isTrue);

      // 4b. Double-clicking a file in Explorer also opens in active editor window (1), NOT mainWin or tabbarWin
      server.commands.clear();
      server.currentWin = mainWin;
      server.cursors[mainWin] = (2, 0);
      await server.serverSession.request('vibrainium_action', ['workspace.double_click']);
      expect(server.currentWin, 1);
      expect(server.commands.any((c) => c.endsWith('/hello.dart')), isTrue);

      // 5. `workspace.toggle` when Explorer is already active closes both mainWin and tabbarWin
      await server.serverSession.request('vibrainium_action', ['workspace.toggle']);
      expect(await app.isOpen(), isFalse);
      expect(server.validWins.contains(mainWin), isFalse);
      expect(server.validWins.contains(tabbarWin), isFalse);

      await server.dispose();
    });

    test('clicking Explorer or VCS in tabbar switches tabs and keeps sidepanel open', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      final app = VibrainiumApp(nvim: Nvim(server.clientSession), vcsList: const []);

      await server.serverSession.request('vibrainium_action', ['workspace.open']);
      final mainWin = app.mainWindowId!;
      final tabbarWin = app.tabbarWindowId!;
      final tabbarBuf = app.tabbarBufferId!;

      final marks = server.bufExtmarks[tabbarBuf]!;
      final wsEndCol = marks[0]['end_col'] as int;
      final sepEndCol = marks[1]['end_col'] as int;

      // 1. Click VCS tab (col >= sepEndCol) -> switches to VCS and restores focus to mainWin
      server.currentWin = tabbarWin;
      server.cursors[tabbarWin] = (1, sepEndCol + 2);
      await server.serverSession.request('vibrainium_action', ['tab.click']);
      expect(await app.isOpen(), isTrue);
      expect(app.activeTab, VibrainiumTab.vcs);
      expect(server.winBufs[mainWin], app.vcsSidebar.bufferId);
      expect(server.currentWin, mainWin);

      // 2. Click VCS tab again while already active -> stays open on VCS
      server.currentWin = tabbarWin;
      server.cursors[tabbarWin] = (1, sepEndCol + 4);
      await server.serverSession.request('vibrainium_action', ['tab.click']);
      expect(await app.isOpen(), isTrue);
      expect(app.activeTab, VibrainiumTab.vcs);
      expect(server.currentWin, mainWin);

      // 3. Click separator (col == wsEndCol) -> keeps current tab and restores focus to mainWin
      server.currentWin = tabbarWin;
      server.cursors[tabbarWin] = (1, wsEndCol);
      await server.serverSession.request('vibrainium_action', ['tab.click']);
      expect(await app.isOpen(), isTrue);
      expect(app.activeTab, VibrainiumTab.vcs);
      expect(server.currentWin, mainWin);

      // 4. Click Explorer tab (col < wsEndCol) -> switches back to Explorer
      server.currentWin = tabbarWin;
      server.cursors[tabbarWin] = (1, 2);
      await server.serverSession.request('vibrainium_action', ['tab.click']);
      expect(await app.isOpen(), isTrue);
      expect(app.activeTab, VibrainiumTab.workspace);
      expect(server.winBufs[mainWin], app.workspaceSidebar.bufferId);
      expect(server.currentWin, mainWin);

      // 5. Re-binds tabbar keymaps on hot reload even when sidepanel is closed
      await app.close();
      expect(await app.isOpen(), isFalse);
      server.bufKeymaps[tabbarBuf]!.clear();
      server.notifications.clear();
      await app.onHotReloaded();
      expect(server.notifications, contains('[Vibrainium] Hot reloaded'));
      expect(
        server.bufKeymaps[tabbarBuf]!.keys,
        containsAll(['<LeftMouse>', '<LeftRelease>', '<Tab>', '<S-Tab>', '1', '2']),
      );

      await server.dispose();
    });

    test('opens bottom panel with Problems [3] tabbar, updates diagnostic counts, and coexists with left sidepanel', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      server.rawDiagnostics = [
        {
          'file': '${tempDir.path}/hello.dart',
          'bufnr': 1,
          'lnum': 3,
          'col': 2,
          'end_lnum': 3,
          'end_col': 5,
          'severity': 1,
          'message': 'Undefined variable x',
          'source': 'dart',
          'code': 'undefined_identifier',
        },
      ];

      final app = VibrainiumApp(nvim: Nvim(server.clientSession), vcsList: const []);

      // 1. Open left sidepanel (`workspace.open`) AND bottom panel (`problems.open`)
      await server.serverSession.request('vibrainium_action', ['workspace.open']);
      await server.serverSession.request('vibrainium_action', ['problems.open']);

      expect(await app.isOpen(), isTrue);
      expect(await app.isBottomPanelOpen(), isTrue);
      expect(app.activeBottomTab, VibrainiumBottomTab.problems);

      final bottomMainWin = app.bottomMainWindowId!;
      final bottomTabWin = app.bottomTabbarWindowId!;
      final bottomTabBuf = app.bottomTabbarBufferId!;
      final probBuf = app.problemsPanel.bufferId!;

      expect(server.winBufs[bottomMainWin], probBuf);
      expect(server.winConfigs[bottomMainWin]!['split'], 'below');
      expect(server.winConfigs[bottomMainWin]!['win'], 1);
      expect(server.winConfigs[bottomTabWin]!['win'], bottomMainWin);
      expect(server.winConfigs[bottomTabWin]!['split'], 'below');
      expect(server.winConfigs[bottomTabWin]!['height'], 1);

      // Bottom tabbar shows Problems tab with live diagnostic count badge
      final bottomTabLine = server.bufLines[bottomTabBuf]!.single;
      expect(bottomTabLine, contains('Problems (󰅚 1 󰀪 0) [3]'));
      expect(
        server.bufKeymaps[bottomTabBuf]!.keys,
        containsAll(['<Tab>', '<S-Tab>', '3', '4']),
      );
      expect(server.bufKeymaps[probBuf]!.keys, containsAll(['<Tab>', '<S-Tab>', '3', '4']));

      final bottomMarks = server.bufExtmarks[bottomTabBuf]!;
      expect(bottomMarks[0]['hl_group'], 'VibrainiumTabActive');
      expect(bottomMarks[1]['hl_group'], 'VibrainiumTabSeparator');

      // 2. Pressing <CR> on the diagnostic row in Problems panel jumps to editor window (1), NOT left sidepanel or bottom panel
      server.currentWin = bottomMainWin;
      server.cursors[bottomMainWin] = (4, 0); // row 4 is the diagnostic entry
      await server.serverSession.request('vibrainium_action', ['problems.enter']);
      expect(server.currentWin, 1);
      expect(server.cursors[1], (3, 2));

      // 2b. Double-clicking (`problems.double_click`) on the diagnostic row in Problems panel also opens in normal editor window (1)
      server.commands.clear();
      server.currentWin = bottomMainWin;
      server.cursors[bottomMainWin] = (4, 0);
      await server.serverSession.request('vibrainium_action', ['problems.double_click']);
      expect(server.currentWin, 1);
      expect(server.commands.any((c) => c.endsWith('/hello.dart')), isTrue);
      expect(server.cursors[1], (3, 2));

      // 3. Clicking bottom tabbar keeps bottom panel open and focuses bottomMainWin
      server.currentWin = bottomTabWin;
      await server.serverSession.request('vibrainium_action', ['bottom_tab.click']);
      expect(await app.isBottomPanelOpen(), isTrue);
      expect(server.currentWin, bottomMainWin);

      // 4. `problems.toggle` closes the bottom panel while leaving the left sidepanel open
      await server.serverSession.request('vibrainium_action', ['problems.toggle']);
      expect(await app.isBottomPanelOpen(), isFalse);
      expect(await app.isOpen(), isTrue);

      // 5. Switching active editor split to window 2 via `workspace.sync_active_file`
      //    propagates active editor pane to `problems.open`, `problems.double_click`, and `workspace.double_click`
      server.validWins.add(2);
      server.winBufs[2] = 0;
      server.currentWin = 2;
      await server.serverSession.request(
        'vibrainium_action',
        ['workspace.sync_active_file', '${tempDir.path}/hello.dart'],
      );

      // Open Problems panel while focused in left sidepanel (`mainWin`);
      // should anchor split below editor window 2 (not `mainWin` or window 1)
      final mainWin = app.mainWindowId!;
      server.currentWin = mainWin;
      await server.serverSession.request('vibrainium_action', ['problems.open']);
      final newBottomMainWin = app.bottomMainWindowId!;
      expect(server.winConfigs[newBottomMainWin]!['win'], 2);

      // Pressing <CR> on diagnostic in Problems panel opens in editor window 2
      server.commands.clear();
      server.currentWin = newBottomMainWin;
      server.cursors[newBottomMainWin] = (4, 0);
      await server.serverSession.request('vibrainium_action', ['problems.enter']);
      expect(server.currentWin, 2);
      expect(server.commands.any((c) => c.contains('split')), isFalse);
      expect(server.commands.any((c) => c.endsWith('/hello.dart')), isTrue);

      // Double-clicking file in Workspace sidebar also opens in editor window 2
      server.commands.clear();
      server.currentWin = mainWin;
      server.cursors[mainWin] = (2, 0);
      await server.serverSession.request('vibrainium_action', ['workspace.double_click']);
      expect(server.currentWin, 2);
      expect(server.commands.any((c) => c.contains('split')), isFalse);
      expect(server.commands.any((c) => c.endsWith('/hello.dart')), isTrue);

      await server.dispose();
    });

    test('routes diff.compare and diff.toggle_mode through shared ViffController', () async {
      final fileA = File('${tempDir.path}/a.dart')..writeAsStringSync('int x = 1;\n');
      final fileB = File('${tempDir.path}/b.dart')..writeAsStringSync('int x = 2;\n');

      final server = _FakeNvimServer(cwd: tempDir.path);
      final app = VibrainiumApp(nvim: Nvim(server.clientSession), vcsList: const []);

      expect(identical(app.vcsSidebar.viff, app.workspaceSidebar.viff), isTrue);

      await server.serverSession.request(
        'vibrainium_action',
        ['diff.compare', fileA.path, fileB.path],
      );
      expect(app.viff.activeTarget, isA<TwoFilesDiffTarget>());
      expect(app.viff.hunks, hasLength(1));

      final initialMode = app.viff.activeMode;
      await server.serverSession.request(
        'vibrainium_action',
        ['diff.toggle_mode'],
      );
      expect(app.viff.activeMode, isNot(initialMode));

      await server.dispose();
    });

    test('maintains independent per-split editor tabbars via winbar and hides global tabline', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      final app = VibrainiumApp(nvim: Nvim(server.clientSession), vcsList: const []);

      // Set up buffers:
      // buf 10: a/widget.dart
      // buf 11: b/widget.dart (same basename to test parent disambiguation)
      // buf 12: main.dart (for split 2)
      for (final b in [10, 11, 12]) {
        server.bufLines[b] = ['// code'];
        server.bufOptions[b] = {'buftype': '', 'filetype': 'dart', 'modified': false};
      }
      server.bufNames[10] = '${tempDir.path}/a/widget.dart';
      server.bufNames[11] = '${tempDir.path}/b/widget.dart';
      server.bufNames[12] = '${tempDir.path}/main.dart';

      // Split 1 (win 1) starts on buf 10; Split 2 (win 2) starts on buf 12
      server.validWins.addAll([1, 2]);
      server.winBufs[1] = 10;
      server.winBufs[2] = 12;
      server.currentWin = 1;

      await server.serverSession.request('vibrainium_action', ['editor_tab.sync']);

      // Hides global tabline and clears tabline expression
      expect(server.globalOptions['showtabline'], 0);
      expect(server.globalOptions['tabline'], '');

      // Even if bufferline.nvim later sets showtabline = 2, the next sync re-zeros it
      server.globalOptions['showtabline'] = 2;
      server.globalOptions['tabline'] = '%!v:lua.nvim_bufferline()';
      await server.serverSession.request('vibrainium_action', ['editor_tab.sync']);
      expect(server.globalOptions['showtabline'], 0);
      expect(server.globalOptions['tabline'], '');

      // Each split tracks only its own tabs
      expect(app.editorTabbar.tabsForWindow(1), [10]);
      expect(app.editorTabbar.tabsForWindow(2), [12]);
      expect(server.winOptions[1]!['winbar'], contains('widget.dart'));
      expect(server.winOptions[1]!['winbar'], isNot(contains('main.dart')));
      expect(server.winOptions[2]!['winbar'], contains('main.dart'));
      expect(server.winOptions[2]!['winbar'], isNot(contains('widget.dart')));

      // Visit buf 11 in Split 1 (win 1) and mark it modified
      server.winBufs[1] = 11;
      server.bufOptions[11]!['modified'] = true;
      await server.serverSession.request('vibrainium_action', ['editor_tab.sync']);

      expect(app.editorTabbar.tabsForWindow(1), [10, 11]);
      expect(app.editorTabbar.tabsForWindow(2), [12]);

      final win1Bar = server.winOptions[1]!['winbar'] as String;
      // Duplicate basenames in split 1 are disambiguated as a/widget.dart and b/widget.dart
      expect(win1Bar, contains('a/widget.dart'));
      expect(win1Bar, contains('b/widget.dart ●'));
      expect(win1Bar, contains('%10@v:lua.VibrainiumWinbarSelect@'));
      expect(win1Bar, contains('%11@v:lua.VibrainiumWinbarClose@✕ %X'));

      // Cycle prev tab in Split 1 (`buffer.prev`) -> switches win 1 back to buf 10 without touching win 2
      server.currentWin = 1;
      await server.serverSession.request('vibrainium_action', ['buffer.prev']);
      expect(server.winBufs[1], 10);
      expect(server.winBufs[2], 12);

      // Click tab 11 in Split 1 (`editor_tab.click` with left button) -> switches win 1 to buf 11
      await server.serverSession.request(
        'vibrainium_action',
        ['editor_tab.click', 1, 11, 'l'],
      );
      expect(server.winBufs[1], 11);
      expect(server.currentWin, 1);

      // Close active tab 11 in Split 1 (`buffer.close`) -> falls back to remaining tab 10 in Split 1
      await server.serverSession.request('vibrainium_action', ['buffer.close']);
      expect(app.editorTabbar.tabsForWindow(1), [10]);
      expect(server.winBufs[1], 10);
      expect(app.editorTabbar.tabsForWindow(2), [12]);

      await server.dispose();
    });

    test('redirects focus away from sidebar and bottom-panel tabbar splits on panel_tabbar.win_enter', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      final app = VibrainiumApp(nvim: Nvim(server.clientSession), vcsList: const []);

      await server.serverSession.request('vibrainium_action', ['workspace.open']);
      final mainWin = app.mainWindowId!;
      final tabbarWin = app.tabbarWindowId!;

      // 1. Landing on _tabbarWin from an editor split (or when bottom panel is closed) redirects to _mainWin
      server.alternateWin = 1;
      server.currentWin = tabbarWin;
      await server.serverSession.request('vibrainium_action', ['panel_tabbar.win_enter']);
      expect(server.currentWin, mainWin);

      // 2. When bottom panel is open, pressing <C-w>j from _mainWin (landing on _tabbarWin with alternateWin == _mainWin)
      //    redirects down into _bottomMainWin!
      await server.serverSession.request('vibrainium_action', ['problems.open']);
      final bottomMainWin = app.bottomMainWindowId!;
      final bottomTabWin = app.bottomTabbarWindowId!;

      server.alternateWin = mainWin;
      server.currentWin = tabbarWin;
      await server.serverSession.request('vibrainium_action', ['panel_tabbar.win_enter']);
      expect(server.currentWin, bottomMainWin);

      // 3. Landing on _bottomTabbarWin redirects to _bottomMainWin
      server.currentWin = bottomTabWin;
      await server.serverSession.request('vibrainium_action', ['panel_tabbar.win_enter']);
      expect(server.currentWin, bottomMainWin);

      // 4. Clicking VCS in _tabbarWin while focused in Explorer (`workspace.click`) switches to VCS
      final tabbarBuf = app.tabbarBufferId!;
      final sepEndCol = server.bufExtmarks[tabbarBuf]![1]['end_col'] as int;
      server.currentWin = tabbarWin;
      server.mousePos = {
        'winid': tabbarWin,
        'line': 1,
        'column': sepEndCol + 3,
        'winrow': 1,
        'wincol': 20,
        'screenrow': 20,
        'screencol': 20,
      };
      await server.serverSession.request('vibrainium_action', ['workspace.click']);
      expect(app.activeTab, VibrainiumTab.vcs);
      expect(server.currentWin, mainWin);

      // 5. Clicking Explorer in _tabbarWin from an editor window (triggering `panel_tabbar.win_enter` with mouse trigger)
      //    switches back to Explorer and focuses _mainWin
      server.currentWin = tabbarWin;
      server.mousePos = {
        'winid': tabbarWin,
        'line': 1,
        'column': 3,
        'winrow': 1,
        'wincol': 3,
        'screenrow': 20,
        'screencol': 3,
      };
      await server.serverSession.request('vibrainium_action', ['panel_tabbar.win_enter', 'mouse']);
      expect(app.activeTab, VibrainiumTab.workspace);
      expect(server.currentWin, mainWin);

      // 6. Pressing <C-w>j (`panel_tabbar.win_enter` with 'key' trigger) ignores stale mousePos on _tabbarWin
      //    and redirects down to _bottomMainWin without switching tabs
      server.alternateWin = mainWin;
      server.currentWin = tabbarWin;
      server.mousePos = {
        'winid': tabbarWin,
        'line': 1,
        'column': sepEndCol + 3,
        'winrow': 1,
        'wincol': 20,
        'screenrow': 20,
        'screencol': 20,
      };
      await server.serverSession.request('vibrainium_action', ['panel_tabbar.win_enter', 'key']);
      expect(app.activeTab, VibrainiumTab.workspace);
      expect(server.currentWin, bottomMainWin);

      await server.dispose();
    });

    test('propagates active split pane across workspace.sync_active_file, visearch, and panels', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      final app = VibrainiumApp(nvim: Nvim(server.clientSession), vcsList: const []);

      // Set up two editor split panes: win 1 and win 2
      for (final b in [10, 11]) {
        server.bufLines[b] = ['// code'];
        server.bufOptions[b] = {'buftype': '', 'filetype': 'dart', 'modified': false};
      }
      server.bufNames[10] = '${tempDir.path}/hello.dart';
      server.bufNames[11] = '${tempDir.path}/sub/nested.dart';
      server.validWins.addAll([1, 2]);
      server.winBufs[1] = 10;
      server.winBufs[2] = 11;

      await server.serverSession.request('vibrainium_action', ['workspace.open']);

      // Simulate switching active split pane to win 2 via workspace.sync_active_file with editorWin = 2
      server.currentWin = 2;
      await server.serverSession.request(
        'vibrainium_action',
        ['workspace.sync_active_file', '${tempDir.path}/sub/nested.dart', 2],
      );
      expect(app.workspaceSidebar.lastActiveEditorWin, 2);
      expect(app.vcsSidebar.lastActiveEditorWin, 2);
      expect(app.problemsPanel.lastActiveEditorWin, 2);
      expect(app.searchPicker.lastActiveEditorWin, 2);

      await server.dispose();
    });

    test('switches bottom panel between Problems [3] and Agents [4] and manages agent terminal split', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      final app = VibrainiumApp(nvim: Nvim(server.clientSession), vcsList: const []);

      // Open Problems [3] bottom tab
      await server.serverSession.request('vibrainium_action', ['problems.open']);
      expect(app.activeBottomTab, VibrainiumBottomTab.problems);
      expect(await app.isBottomPanelOpen(), isTrue);
      expect(app.agentsPanel.termWindowId, isNull);

      final bottomTabBuf = app.bottomTabbarBufferId!;
      expect(server.bufLines[bottomTabBuf]!.single, contains('Problems [3]'));
      expect(server.bufLines[bottomTabBuf]!.single, contains('Agents [4]'));

      // Cycle to Agents [4] bottom tab
      await server.serverSession.request('vibrainium_action', ['bottom_tab.next']);
      expect(app.activeBottomTab, VibrainiumBottomTab.agents);
      expect(app.agentsPanel.treeWindowId, app.bottomMainWindowId);
      expect(app.agentsPanel.termWindowId, isNotNull);

      // Start an Antigravity chat and a Claude Code chat
      await server.serverSession.request('vibrainium_action', ['agent.new_antigravity']);
      await server.serverSession.request('vibrainium_action', ['agent.new_claude']);
      expect(app.agentsPanel.sessions, hasLength(2));
      expect(server.bufLines[bottomTabBuf]!.single, contains('Agents (2) [4]'));

      // Switching back to Problems [3] closes the agent terminal split cleanly
      await server.serverSession.request('vibrainium_action', ['bottom_tab.problems']);
      expect(app.activeBottomTab, VibrainiumBottomTab.problems);
      expect(app.agentsPanel.termWindowId, isNull);
      expect(app.agentsPanel.sessions, hasLength(2));

      await server.dispose();
    });

    test('left_panel.toggle and bottom_panel.toggle close and reopen on last active tab', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      final app = VibrainiumApp(nvim: Nvim(server.clientSession), vcsList: const []);

      // 1. Left panel starts closed; left_panel.toggle opens default Explorer tab
      expect(await app.isOpen(), isFalse);
      await server.serverSession.request('vibrainium_action', ['left_panel.toggle']);
      expect(await app.isOpen(), isTrue);
      expect(app.activeTab, VibrainiumTab.workspace);

      // Switch to VCS tab, then toggle left panel closed and reopened -> restores VCS tab
      await server.serverSession.request('vibrainium_action', ['vcs.open']);
      expect(app.activeTab, VibrainiumTab.vcs);

      await server.serverSession.request('vibrainium_action', ['left_panel.toggle']);
      expect(await app.isOpen(), isFalse);

      await server.serverSession.request('vibrainium_action', ['left_panel.toggle']);
      expect(await app.isOpen(), isTrue);
      expect(app.activeTab, VibrainiumTab.vcs);

      // 2. Bottom panel starts closed; bottom_panel.toggle opens default Problems tab
      expect(await app.isBottomPanelOpen(), isFalse);
      await server.serverSession.request('vibrainium_action', ['bottom_panel.toggle']);
      expect(await app.isBottomPanelOpen(), isTrue);
      expect(app.activeBottomTab, VibrainiumBottomTab.problems);

      // Switch to Agents tab, then toggle bottom panel closed and reopened -> restores Agents tab
      await server.serverSession.request('vibrainium_action', ['agents.open']);
      expect(app.activeBottomTab, VibrainiumBottomTab.agents);

      await server.serverSession.request('vibrainium_action', ['bottom_panel.toggle']);
      expect(await app.isBottomPanelOpen(), isFalse);

      await server.serverSession.request('vibrainium_action', ['bottom_panel.toggle']);
      expect(await app.isBottomPanelOpen(), isTrue);
      expect(app.activeBottomTab, VibrainiumBottomTab.agents);

      await server.dispose();
    });

    test('concurrent search.confirm and editor_tab.sync TOCTOU race closes padding window and opens file', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      final app = VibrainiumApp(nvim: Nvim(server.clientSession), vcsList: const []);

      await server.serverSession.request('vibrainium_action', ['workspace.open']);
      await server.serverSession.request('vibrainium_action', ['search.files']);
      expect(await app.searchPicker.isOpen(), isTrue);

      final padWin = app.searchPicker.paddingWindowId!;
      expect(server.validWins, contains(padWin));

      // Simulate nvim_win_get_config throwing RpcException when a floating window closes mid-inspection
      final origOnRequest = server.serverSession.onRequest!;
      server.serverSession.onRequest = (method, params) async {
        if (method == 'nvim_win_get_config') {
          final w = params[0] as int;
          if (!server.validWins.contains(w)) {
            throw StateError('Invalid window id: $w');
          }
        }
        return origOnRequest(method, params);
      };

      // Dispatch concurrent notifications just like Neovim's autocmds + <CR>
      server.serverSession.notify('vibrainium_action', ['search.query_changed', 'hello']);
      server.serverSession.notify('vibrainium_action', ['search.confirm']);
      server.serverSession.notify('vibrainium_action', ['editor_tab.sync']);

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(await app.searchPicker.isOpen(), isFalse);
      expect(app.searchPicker.paddingWindowId, isNull);
      expect(server.validWins, isNot(contains(padWin)));
      expect(
        server.commands.any((c) => c.startsWith('edit ') && c.endsWith('hello.dart')),
        isTrue,
      );

      await server.dispose();
    });

    test('problems.open while focused in left sidepanel anchors below right pane even when right pane holds dashboard or viff buffer', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      final app = VibrainiumApp(nvim: Nvim(server.clientSession), vcsList: const []);

      // 1. Simulate startup where window 1 holds a dashboard buffer (buftype = 'nofile')
      server.bufLines[10] = ['Dashboard'];
      server.bufOptions[10] = {
        'buftype': 'nofile',
        'filetype': 'snacks_dashboard',
        'modified': false,
      };
      server.winBufs[1] = 10;
      server.currentWin = 1;

      // VimEnter opens left sidepanel (`workspace.open`), which moves focus to `mainWin`
      await server.serverSession.request('vibrainium_action', ['workspace.open']);
      final mainWin = app.mainWindowId!;
      expect(server.currentWin, mainWin);

      // Run `:Vibrainium Problems.Open` (`problems.open`) while left sidepanel has focus
      await server.serverSession.request('vibrainium_action', ['problems.open']);
      final bottomWin1 = app.bottomMainWindowId!;
      expect(server.winConfigs[bottomWin1]!['split'], 'below');
      expect(server.winConfigs[bottomWin1]!['win'], 1);
      expect(server.winConfigs[bottomWin1]!['win'], isNot(mainWin));

      // Close bottom panel and simulate right pane holding a `viff` diff buffer
      await server.serverSession.request('vibrainium_action', ['problems.close']);
      server.bufOptions[10] = {
        'buftype': 'nofile',
        'filetype': 'viff',
        'modified': false,
      };
      server.currentWin = mainWin;

      await server.serverSession.request('vibrainium_action', ['problems.open']);
      final bottomWin2 = app.bottomMainWindowId!;
      expect(server.winConfigs[bottomWin2]!['split'], 'below');
      expect(server.winConfigs[bottomWin2]!['win'], 1);
      expect(server.winConfigs[bottomWin2]!['win'], isNot(mainWin));

      await server.dispose();
    });

    test('editor tabbar context menu supports Copy Path, Add File to Chat, Reveal in Finder, and Split submenu', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      final revealedCommands = <(String, List<String>)>[];
      final nvim = Nvim(server.clientSession);
      final wsSidebar = WorkspaceSidebar(
        nvim: nvim,
        bindRpc: false,
        processRunner: (executable, arguments) async {
          revealedCommands.add((executable, arguments));
          return ProcessResult(0, 0, '', '');
        },
      );
      final app = VibrainiumApp(
        nvim: nvim,
        vcsList: const [],
        workspaceSidebar: wsSidebar,
      );

      for (final b in [10, 11, 12]) {
        server.bufLines[b] = ['// code'];
        server.bufOptions[b] = {
          'buftype': '',
          'filetype': 'dart',
          'modified': false,
        };
      }
      server.bufNames[10] = '${tempDir.path}/hello.dart';
      server.bufNames[11] = '${tempDir.path}/sub/nested.dart';
      server.bufNames[12] = '${tempDir.path}/third.dart';
      server.validWins.add(1);
      server.winBufs[1] = 10;
      server.currentWin = 1;

      await server.serverSession.request('vibrainium_action', ['editor_tab.sync']);
      server.winBufs[1] = 11;
      await server.serverSession.request('vibrainium_action', ['editor_tab.sync']);
      server.winBufs[1] = 12;
      await server.serverSession.request('vibrainium_action', ['editor_tab.sync']);
      expect(app.editorTabbar.tabsForWindow(1), [10, 11, 12]);

      const expectedRootMenuLabels = [
        'Copy Path',
        'Add File to Chat',
        'Reveal in Finder',
        'Split',
        'Close Others',
        'Close to the Right',
        'Close All',
      ];

      // 1. Right-click on the first tab (`hello.dart`, buf 10) via column hit-testing (`editor_tab.right_click`)
      await server.serverSession.request(
        'vibrainium_action',
        ['editor_tab.right_click', 1, 3, 1, 10],
      );
      expect(app.editorTabbar.contextMenu.isOpen, isTrue);
      expect(
        app.editorTabbar.contextMenu.items.map((i) => i.label).toList(),
        expectedRootMenuLabels,
      );

      // Select "Copy Path" (index 0)
      await server.serverSession.request('vibrainium_action', ['editor_tab.menu_select:0']);
      expect(app.editorTabbar.contextMenu.isOpen, isFalse);
      expect(server.registers['+'], '${tempDir.path}/hello.dart');
      expect(server.registers['"'], '${tempDir.path}/hello.dart');
      expect(
        server.notifications.any((n) => n.contains('Copied path: ${tempDir.path}/hello.dart')),
        isTrue,
      );

      // 2. Right-click on the second tab (`sub/nested.dart`, buf 11) via `editor_tab.click` with button 'r'
      // First start an active AI chat so "Add File to Chat" sends directly to the active chat
      await server.serverSession.request('vibrainium_action', ['agent.new_antigravity']);
      server.notifications.clear();

      await server.serverSession.request(
        'vibrainium_action',
        ['editor_tab.click', 1, 11, 'r', 1, 20],
      );
      expect(app.editorTabbar.contextMenu.isOpen, isTrue);
      await server.serverSession.request('vibrainium_action', ['editor_tab.menu_select:1']);
      expect(app.editorTabbar.contextMenu.isOpen, isFalse);
      expect(
        server.notifications.any((n) => n.contains('Sent @sub/nested.dart to')),
        isTrue,
      );

      // 3. Select "Reveal in Finder" (index 2)
      await server.serverSession.request(
        'vibrainium_action',
        ['editor_tab.click', 1, 10, 'r', 1, 10],
      );
      expect(app.editorTabbar.contextMenu.isOpen, isTrue);
      await server.serverSession.request('vibrainium_action', ['editor_tab.menu_select:2']);
      expect(app.editorTabbar.contextMenu.isOpen, isFalse);
      expect(revealedCommands, isNotEmpty);
      expect(revealedCommands.last.$2, contains('${tempDir.path}/hello.dart'));

      // 4. Open "Split" submenu (index 3 or `editor_tab.menu_right`), test "← Back", then "Split Right"
      await server.serverSession.request(
        'vibrainium_action',
        ['editor_tab.click', 1, 10, 'r', 1, 10],
      );
      expect(app.editorTabbar.contextMenu.isOpen, isTrue);
      await server.serverSession.request('vibrainium_action', ['editor_tab.menu_select:3']);
      expect(app.editorTabbar.contextMenu.isOpen, isTrue);
      expect(
        app.editorTabbar.contextMenu.items.map((i) => i.label).toList(),
        ['Split Up', 'Split Down', 'Split Left', 'Split Right', '← Back'],
      );

      // Navigate back to root context menu via `editor_tab.menu_back`
      await server.serverSession.request('vibrainium_action', ['editor_tab.menu_back']);
      expect(
        app.editorTabbar.contextMenu.items.map((i) => i.label).toList(),
        expectedRootMenuLabels,
      );

      // Re-open Split submenu and choose "Split Right" (index 3)
      await server.serverSession.request('vibrainium_action', ['editor_tab.menu_select:3']);
      final winsBefore = server.validWins.toSet();
      await server.serverSession.request('vibrainium_action', ['editor_tab.menu_select:3']);
      expect(app.editorTabbar.contextMenu.isOpen, isFalse);

      final newSplitWins = server.validWins.difference(winsBefore);
      expect(newSplitWins, hasLength(1));
      final splitWin = newSplitWins.single;
      expect(server.winConfigs[splitWin]!['split'], 'right');
      expect(server.winConfigs[splitWin]!['win'], 1);
      expect(server.winBufs[splitWin], 10);
      expect(app.editorTabbar.tabsForWindow(splitWin), contains(10));

      // 5. Select "Close to the Right" (index 5) on buf 11 in win 1 -> closes buf 12, keeps [10, 11]
      await server.serverSession.request(
        'vibrainium_action',
        ['editor_tab.click', 1, 11, 'r', 1, 20],
      );
      expect(app.editorTabbar.contextMenu.isOpen, isTrue);
      await server.serverSession.request('vibrainium_action', ['editor_tab.menu_select:5']);
      expect(app.editorTabbar.contextMenu.isOpen, isFalse);
      expect(app.editorTabbar.tabsForWindow(1), [10, 11]);
      expect(server.winBufs[1], 11);

      // 6. Select "Close Others" (index 4) on buf 10 in win 1 -> closes buf 11, keeps [10]
      await server.serverSession.request(
        'vibrainium_action',
        ['editor_tab.click', 1, 10, 'r', 1, 10],
      );
      expect(app.editorTabbar.contextMenu.isOpen, isTrue);
      await server.serverSession.request('vibrainium_action', ['editor_tab.menu_select:4']);
      expect(app.editorTabbar.contextMenu.isOpen, isFalse);
      expect(app.editorTabbar.tabsForWindow(1), [10]);
      expect(server.winBufs[1], 10);
      // Other split (`splitWin`) still keeps its own tab [10] untouched
      expect(app.editorTabbar.tabsForWindow(splitWin), [10]);

      // 7. Select "Close All" (index 6) in win 1 -> clears tabs in win 1 without closing `splitWin` tabs
      await server.serverSession.request(
        'vibrainium_action',
        ['editor_tab.click', 1, 10, 'r', 1, 10],
      );
      expect(app.editorTabbar.contextMenu.isOpen, isTrue);
      await server.serverSession.request('vibrainium_action', ['editor_tab.menu_select:6']);
      expect(app.editorTabbar.contextMenu.isOpen, isFalse);
      expect(app.editorTabbar.tabsForWindow(1), isEmpty);
      expect(app.editorTabbar.tabsForWindow(splitWin), [10]);

      await server.dispose();
    });

    test('opening left panel when bottom panel is already open creates a top-level full-height left split', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      final app = VibrainiumApp(nvim: Nvim(server.clientSession), vcsList: const []);

      // 1. Open bottom panel first (`problems.open`) while left panel is closed
      await server.serverSession.request('vibrainium_action', ['problems.open']);
      expect(await app.isBottomPanelOpen(), isTrue);
      expect(await app.isOpen(), isFalse);
      final bottomMainWin = app.bottomMainWindowId!;
      expect(server.currentWin, bottomMainWin);

      // 2. Open left panel while focused in bottom panel -> uses `win: -1, split: 'left'`
      await server.serverSession.request('vibrainium_action', ['workspace.open']);
      expect(await app.isOpen(), isTrue);
      expect(await app.isBottomPanelOpen(), isTrue);

      final mainWin1 = app.mainWindowId!;
      final tabbarWin1 = app.tabbarWindowId!;
      final searchWin1 = app.workspaceSidebar.searchPrompt.windowId!;

      expect(server.winConfigs[mainWin1]!['win'], -1);
      expect(server.winConfigs[mainWin1]!['split'], 'left');
      expect(server.winConfigs[mainWin1]!['width'], app.sidebarWidth);
      expect(server.winConfigs[tabbarWin1]!['win'], mainWin1);
      expect(server.winConfigs[tabbarWin1]!['split'], 'below');
      expect(server.winConfigs[searchWin1]!['win'], mainWin1);
      expect(server.winConfigs[searchWin1]!['split'], 'below');

      // 3. Close left panel, switch bottom panel to Agents tab, focus editor window 1, and reopen left panel
      await server.serverSession.request('vibrainium_action', ['close']);
      expect(await app.isOpen(), isFalse);

      await server.serverSession.request('vibrainium_action', ['agents.open']);
      expect(app.activeBottomTab, VibrainiumBottomTab.agents);
      expect(app.agentsPanel.termWindowId, isNotNull);

      server.currentWin = 1;
      await server.serverSession.request('vibrainium_action', ['left_panel.toggle']);
      expect(await app.isOpen(), isTrue);
      final mainWin2 = app.mainWindowId!;
      expect(server.winConfigs[mainWin2]!['win'], -1);
      expect(server.winConfigs[mainWin2]!['split'], 'left');
      expect(app.agentsPanel.termWindowId, isNotNull);
      expect(server.validWins.contains(app.agentsPanel.termWindowId), isTrue);

      await server.dispose();
    });

    test('coordinates single active context menu across editorTabbar and workspaceSidebar on cross-window right-click', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      server.bufLines[10] = ['void main() {}'];
      server.bufNames[10] = '${tempDir.path}/hello.dart';
      server.bufOptions[10] = {'buftype': '', 'filetype': 'dart', 'buflisted': true};
      server.winBufs[1] = 10;

      final app = VibrainiumApp(nvim: Nvim(server.clientSession), vcsList: const []);
      await server.serverSession.request('vibrainium_action', ['workspace.open']);
      await server.serverSession.request('vibrainium_action', ['editor_tab.sync']);

      final sidebarWin = app.mainWindowId!;
      server.currentWin = 1;

      // 1. Right-click editor winbar tab -> opens editorTabbar.contextMenu
      await server.serverSession.request('vibrainium_action', [
        'editor_tab.right_click',
        1,
        4,
        1,
        40,
      ]);
      expect(app.editorTabbar.contextMenu.isOpen, isTrue);
      expect(app.workspaceSidebar.contextMenu.isOpen, isFalse);

      // 2. Right-click Explorer row 2 while editorTabbar.contextMenu is open ->
      //    closes editorTabbar.contextMenu and opens workspaceSidebar.contextMenu on row 2
      await server.serverSession.request('vibrainium_action', [
        'workspace.context_menu',
        sidebarWin,
        2,
        2,
        4,
        2,
        4,
      ]);
      expect(app.editorTabbar.contextMenu.isOpen, isFalse);
      expect(app.workspaceSidebar.contextMenu.isOpen, isTrue);
      expect(server.cursors[sidebarWin], (2, 0));

      // 3. Right-click back on editor winbar tab -> closes workspaceSidebar.contextMenu and opens editorTabbar.contextMenu
      await server.serverSession.request('vibrainium_action', [
        'editor_tab.right_click',
        1,
        4,
        1,
        40,
      ]);
      expect(app.workspaceSidebar.contextMenu.isOpen, isFalse);
      expect(app.editorTabbar.contextMenu.isOpen, isTrue);

      // 4. Stale menu_close with mismatched buffer ID does not close editorTabbar.contextMenu
      await server.serverSession.request('vibrainium_action', [
        'editor_tab.menu_close',
        999999,
      ]);
      expect(app.editorTabbar.contextMenu.isOpen, isTrue);

      await server.dispose();
    });
  });
}
