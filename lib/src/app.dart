import 'dart:convert';

import 'package:vivcs/vivcs.dart';
import 'package:viworkspace/viworkspace.dart';

/// Active view inside the unified Vibrainium sidepanel.
enum VibrainiumTab {
  workspace,
  vcs,
}

/// Main application coordinator for the `vibrainium` Neovim RPC process.
/// Manages a unified left sidepanel window with a 1-line bottom tabbar split
/// and routes RPC actions to `viworkspace` and `vivcs`.
class VibrainiumApp {
  final Nvim nvim;
  final int sidebarWidth;
  final Future<void> Function()? onShutdown;
  late final ViffSidebar vcsSidebar;
  late final WorkspaceSidebar workspaceSidebar;

  static const String _wsTabLabel = ' 󰙅 Explorer [1] ';
  static const String _tabSeparator = '│';
  static const String _vcsTabCore = ' 󰊢 VCS [2] ';

  static const Map<String, String> _tabKeymaps = {
    '<Tab>': 'tab.next',
    '<S-Tab>': 'tab.prev',
    '1': 'tab.workspace',
    '2': 'tab.vcs',
  };

  VibrainiumTab _activeTab = VibrainiumTab.workspace;
  int? _mainWin;
  int? _tabbarWin;
  int? _tabbarBuf;
  int? _tabbarNsId;
  bool _tabbarHighlightsInitialized = false;

  VibrainiumApp({
    required this.nvim,
    List<Vcs> vcsList = const [Git(), Svn()],
    this.sidebarWidth = 38,
    this.onShutdown,
  }) {
    vcsSidebar = ViffSidebar(
      nvim: nvim,
      vcsList: vcsList,
      sidebarWidth: sidebarWidth,
      extraKeymaps: _tabKeymaps,
      bindRpc: false,
    );
    workspaceSidebar = WorkspaceSidebar(
      nvim: nvim,
      sidebarWidth: sidebarWidth,
      extraKeymaps: _tabKeymaps,
      bindRpc: false,
    );
    nvim.rpc.onRequest = _handleRpc;
    nvim.rpc.onNotification = (method, params) async {
      await _handleRpc(method, params);
    };
  }

  VibrainiumTab get activeTab => _activeTab;
  int? get mainWindowId => _mainWin;
  int? get tabbarWindowId => _tabbarWin;
  int? get tabbarBufferId => _tabbarBuf;

  Future<bool> isOpen() async {
    final win = _mainWin;
    if (win == null) return false;
    return nvim.winIsValid(win);
  }

  Future<void> openTab(VibrainiumTab tab) async {
    await vcsSidebar.closeModals();
    await workspaceSidebar.closeModals();
    _activeTab = tab;

    final targetBuf = tab == VibrainiumTab.workspace
        ? await workspaceSidebar.ensureBuffer()
        : await vcsSidebar.ensureBuffer();

    if (!await isOpen()) {
      final mainWin = await nvim.openWin(targetBuf, true, {
        'split': 'left',
        'width': sidebarWidth,
        'style': 'minimal',
      });
      _mainWin = mainWin;
      await _configureMainWin(mainWin);
    } else {
      final mainWin = _mainWin!;
      await nvim.winSetBuf(mainWin, targetBuf);
      await _configureMainWin(mainWin);
      await nvim.setCurrentWin(mainWin);
    }

    await _ensureTabbarWin();
    _syncAttachedWindows();
    await _renderTabbar();

    if (tab == VibrainiumTab.workspace) {
      await workspaceSidebar.refresh();
    } else {
      await vcsSidebar.refresh(rescanRepos: vcsSidebar.repos.isEmpty);
    }
  }

  Future<void> toggleTab(VibrainiumTab tab) async {
    if (await isOpen()) {
      if (_activeTab == tab) {
        await close();
      } else {
        await openTab(tab);
      }
    } else {
      await openTab(tab);
    }
  }

  Future<void> cycleTab(int delta) async {
    final next = _activeTab == VibrainiumTab.workspace
        ? VibrainiumTab.vcs
        : VibrainiumTab.workspace;
    await openTab(next);
  }

  Future<void> handleTabbarClick() async {
    final tabWin = _tabbarWin;
    if (tabWin == null || !await nvim.winIsValid(tabWin)) return;

    final (_, col) = await nvim.winGetCursor(tabWin);
    final wsBytes = utf8.encode(_wsTabLabel).length;
    final sepBytes = utf8.encode(_tabSeparator).length;

    if (col < wsBytes) {
      await openTab(VibrainiumTab.workspace);
    } else if (col >= wsBytes + sepBytes) {
      await openTab(VibrainiumTab.vcs);
    } else {
      final mainWin = _mainWin;
      if (mainWin != null && await nvim.winIsValid(mainWin)) {
        await nvim.setCurrentWin(mainWin);
      }
    }
  }

  Future<void> close() async {
    await vcsSidebar.closeModals();
    await workspaceSidebar.closeModals();
    vcsSidebar.attachWindow(null);
    workspaceSidebar.attachWindow(null);

    final tabWin = _tabbarWin;
    _tabbarWin = null;
    if (tabWin != null && await nvim.winIsValid(tabWin)) {
      await nvim.winClose(tabWin, force: true);
    }

    final mainWin = _mainWin;
    _mainWin = null;
    if (mainWin != null && await nvim.winIsValid(mainWin)) {
      await nvim.winClose(mainWin, force: true);
    }
  }

  Future<void> onHotReloaded() async {
    _tabbarHighlightsInitialized = false;
    await vcsSidebar.onHotReloaded();
    await workspaceSidebar.onHotReloaded();
    final tabBuf = _tabbarBuf;
    if (tabBuf != null && await nvim.bufIsValid(tabBuf)) {
      await _bindTabbarKeys(tabBuf);
    }
    if (await isOpen()) {
      await _ensureTabbarWin();
      await _renderTabbar();
    }
  }

  void _syncAttachedWindows() {
    final excluded = <int>{
      if (_mainWin != null) _mainWin!,
      if (_tabbarWin != null) _tabbarWin!,
    };
    workspaceSidebar.attachWindow(
      _activeTab == VibrainiumTab.workspace ? _mainWin : null,
      excludedWins: excluded,
    );
    vcsSidebar.attachWindow(
      _activeTab == VibrainiumTab.vcs ? _mainWin : null,
      excludedWins: excluded,
    );
  }

  Future<void> _configureMainWin(int win) async {
    await nvim.winSetOption(win, 'number', false);
    await nvim.winSetOption(win, 'relativenumber', false);
    await nvim.winSetOption(win, 'signcolumn', 'no');
    await nvim.winSetOption(win, 'foldcolumn', '0');
    await nvim.winSetOption(win, 'statuscolumn', '');
    await nvim.winSetOption(win, 'wrap', false);
    await nvim.winSetOption(win, 'cursorline', true);
    await nvim.winSetOption(win, 'winfixwidth', true);
  }

  Future<void> _ensureTabbarHighlights() async {
    _tabbarNsId ??= await nvim.createNamespace('vibrainium_tabbar');
    if (_tabbarHighlightsInitialized) return;
    _tabbarHighlightsInitialized = true;

    const groups = <String, Map<String, Object?>>{
      'VibrainiumTabActive': {'bold': true, 'link': 'TabLineSel'},
      'VibrainiumTabInactive': {'link': 'TabLine'},
      'VibrainiumTabSeparator': {'link': 'WinSeparator'},
    };

    for (final entry in groups.entries) {
      await nvim.setHl(0, entry.key, entry.value);
    }
  }

  Future<void> _ensureTabbarWin() async {
    final mainWin = _mainWin;
    if (mainWin == null || !await nvim.winIsValid(mainWin)) return;

    await _ensureTabbarHighlights();

    var buf = _tabbarBuf;
    if (buf == null || !await nvim.bufIsValid(buf)) {
      buf = await nvim.createBuf(listed: false, scratch: true);
      _tabbarBuf = buf;
      await nvim.bufSetOption(buf, 'buftype', 'nofile');
      await nvim.bufSetOption(buf, 'bufhidden', 'hide');
      await nvim.bufSetOption(buf, 'swapfile', false);
      await nvim.bufSetOption(buf, 'filetype', 'vibrainium-tabbar');
    }
    await _bindTabbarKeys(buf);

    final existingWin = _tabbarWin;
    if (existingWin == null || !await nvim.winIsValid(existingWin)) {
      final tabWin = await nvim.openWin(buf, false, {
        'win': mainWin,
        'split': 'below',
        'height': 1,
        'style': 'minimal',
      });
      _tabbarWin = tabWin;
      await nvim.winSetOption(tabWin, 'number', false);
      await nvim.winSetOption(tabWin, 'relativenumber', false);
      await nvim.winSetOption(tabWin, 'signcolumn', 'no');
      await nvim.winSetOption(tabWin, 'foldcolumn', '0');
      await nvim.winSetOption(tabWin, 'statuscolumn', '');
      await nvim.winSetOption(tabWin, 'wrap', false);
      await nvim.winSetOption(tabWin, 'cursorline', false);
      await nvim.winSetOption(tabWin, 'winfixheight', true);
      await nvim.winSetOption(tabWin, 'winfixwidth', true);
    }
  }

  Future<void> _bindTabbarKeys(int buf) async {
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<LeftMouse>',
      "<LeftMouse><Cmd>lua require('vibrainium').action('tab.click')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<LeftRelease>',
      "<LeftRelease><Cmd>lua require('vibrainium').action('tab.click')<CR>",
    );
    const mappings = <String, String>{
      '<CR>': 'tab.click',
      'q': 'close',
      'H': 'reload',
      ..._tabKeymaps,
    };
    for (final entry in mappings.entries) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        entry.key,
        "<Cmd>lua require('vibrainium').action('${entry.value}')<CR>",
      );
    }
  }

  Future<void> _renderTabbar() async {
    final buf = _tabbarBuf;
    final nsId = _tabbarNsId;
    if (buf == null || nsId == null || !await nvim.bufIsValid(buf)) return;

    const wsLabel = _wsTabLabel;
    const sep = _tabSeparator;
    const vcsCore = _vcsTabCore;
    final usedChars = wsLabel.runes.length + sep.runes.length + vcsCore.runes.length;
    final padCount = (sidebarWidth - usedChars).clamp(0, sidebarWidth);
    final vcsLabel = '$vcsCore${' ' * padCount}';
    final line = '$wsLabel$sep$vcsLabel';

    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetLines(buf, lines: [line]);
    await nvim.bufSetOption(buf, 'modifiable', false);

    final wsBytes = utf8.encode(wsLabel).length;
    final sepBytes = utf8.encode(sep).length;
    final vcsBytes = utf8.encode(vcsLabel).length;

    final wsGroup = _activeTab == VibrainiumTab.workspace
        ? 'VibrainiumTabActive'
        : 'VibrainiumTabInactive';
    final vcsGroup = _activeTab == VibrainiumTab.vcs
        ? 'VibrainiumTabActive'
        : 'VibrainiumTabInactive';

    await nvim.bufClearNamespace(buf, nsId);
    await nvim.bufSetExtmark(buf, nsId, 0, 0, {
      'end_col': wsBytes,
      'hl_group': wsGroup,
    });
    await nvim.bufSetExtmark(buf, nsId, 0, wsBytes, {
      'end_col': wsBytes + sepBytes,
      'hl_group': 'VibrainiumTabSeparator',
    });
    await nvim.bufSetExtmark(buf, nsId, 0, wsBytes + sepBytes, {
      'end_col': wsBytes + sepBytes + vcsBytes,
      'hl_group': vcsGroup,
    });
  }

  Future<Object?> _handleRpc(String method, List<Object?> params) async {
    if (method == 'vibrainium_shutdown') {
      if (onShutdown != null) {
        await onShutdown!();
      }
      return true;
    }
    final action = (method == 'vibrainium_action' || method == 'viff_action') &&
            params.isNotEmpty
        ? params.first.toString()
        : method;

    switch (action) {
      case 'tab.click':
        await handleTabbarClick();
        return true;
      case 'tab.next':
        await cycleTab(1);
        return true;
      case 'tab.prev':
        await cycleTab(-1);
        return true;
      case 'tab.workspace':
      case 'workspace.open':
        await openTab(VibrainiumTab.workspace);
        return true;
      case 'tab.vcs':
      case 'open':
      case 'vcs.open':
        await openTab(VibrainiumTab.vcs);
        return true;
      case 'workspace.toggle':
        await toggleTab(VibrainiumTab.workspace);
        return true;
      case 'toggle':
      case 'vcs.toggle':
        await toggleTab(VibrainiumTab.vcs);
        return true;
      case 'close':
      case 'workspace.close':
      case 'vcs.close':
        await close();
        return true;
      case 'reload':
        final res = await vcsSidebar.handleAction(action);
        await workspaceSidebar.onHotReloaded();
        _tabbarHighlightsInitialized = false;
        final tabBuf = _tabbarBuf;
        if (tabBuf != null && await nvim.bufIsValid(tabBuf)) {
          await _bindTabbarKeys(tabBuf);
        }
        if (await isOpen()) {
          await _ensureTabbarWin();
          await _renderTabbar();
        }
        return res;
    }

    if (action.startsWith('workspace.')) {
      return workspaceSidebar.handleAction(action);
    }
    return vcsSidebar.handleAction(action);
  }
}
