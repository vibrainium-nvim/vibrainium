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
  final Map<int, Map<String, String>> bufKeymaps = {};
  final Map<int, List<Map<String, Object?>>> bufExtmarks = {};
  final Set<int> validWins = {1};
  final Map<int, int> winBufs = {1: 0};
  final Map<int, Map<String, Object?>> winConfigs = {};
  final Map<int, Map<String, Object?>> winOptions = {};
  final Map<int, (int, int)> cursors = {1: (1, 0)};
  final List<String> notifications = [];
  final List<String> commands = [];
  int currentWin = 1;

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
        final id = _nextBuf++;
        bufLines[id] = [];
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
        }
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
      case 'nvim_win_get_buf':
        return winBufs[params[0] as int] ?? 0;
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
        return null;
      case 'nvim_get_option_value':
        if (params[0] == 'columns') return 120;
        if (params[0] == 'lines') return 40;
        return null;
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
      await app.onHotReloaded();
      expect(
        server.bufKeymaps[tabbarBuf]!.keys,
        containsAll(['<LeftMouse>', '<LeftRelease>', '<Tab>', '<S-Tab>', '1', '2']),
      );

      await server.dispose();
    });
  });
}
