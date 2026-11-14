import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:viagent/viagent.dart';
import 'package:viproblems/viproblems.dart';
import 'package:visearch/visearch.dart';
import 'package:vivcs/vivcs.dart';
import 'package:viworkspace/viworkspace.dart';

import 'editor_home.dart';
import 'editor_tabbar.dart';
import 'markdown/markdown_preview_manager.dart';

/// Active view inside the unified Vibrainium left sidepanel.
enum VibrainiumTab {
  workspace,
  vcs,
}

/// Active view inside the unified Vibrainium bottom panel.
enum VibrainiumBottomTab {
  problems,
  agents,
}

/// Main application coordinator for the `vibrainium` Neovim RPC process.
/// Manages a unified left sidepanel window with a 1-line bottom tabbar split,
/// a unified bottom panel window with a 1-line bottom tabbar split,
/// and routes RPC actions to `viworkspace`, `vivcs`, `viproblems`, `viagent`, and `visearch`.
class VibrainiumApp {
  final Nvim nvim;
  final int sidebarWidth;
  final int bottomPanelHeight;
  final String? socketPath;
  final String? devPackagePath;
  final Future<void> Function()? onShutdown;
  late final ViffController viff;
  late final VivcsSidebar vcsSidebar;
  late final WorkspaceSidebar workspaceSidebar;
  late final ProblemsPanel problemsPanel;
  late final AgentsPanel agentsPanel;
  late final VisearchPicker searchPicker;
  late final EditorTabbar editorTabbar;
  late final EditorHomeView editorHome;
  late final BufferPreviewManager bufferPreview;
  BufferPreviewManager get markdownPreview => bufferPreview;

  static const String _wsTabLabel = ' 󰙅 Explorer [1] ';
  static const String _tabSeparator = '│';
  static const String _vcsTabCore = ' 󰊢 VCS [2] ';

  static const Map<String, String> _tabKeymaps = {
    '<Tab>': 'tab.next',
    '<S-Tab>': 'tab.prev',
    '1': 'tab.workspace',
    '2': 'tab.vcs',
  };

  static const Map<String, String> _bottomTabKeymaps = {
    '<Tab>': 'bottom_tab.next',
    '<S-Tab>': 'bottom_tab.prev',
    '3': 'bottom_tab.problems',
    '4': 'bottom_tab.agents',
  };

  static const Set<String> _nonEditorFiletypes = {
    'viworkspace',
    'viff',
    'viff-picker',
    'viff-menu',
    'vivcs',
    'vivcs-picker',
    'vivcs-menu',
    'viproblems',
    'viproblems-detail',
    'viagent',
    'viagent-term',
    'viagent-picker',
    'viagent-prompt',
    'viagent-confirm',
    'viagent-menu',
    'vibrainium-tabbar',
    'vibrainium-bottom-tabbar',
    'vibrainium-tab-menu',
    'viworkspace-prompt',
    'viworkspace-confirm',
    'viworkspace-menu',
    'viworkspace-search',
    'visearch-padding',
    'visearch-prompt',
    'visearch-results',
    'visearch-preview',
    'visearch-dropdown',
    'vibrainium-markdown-preview',
    'vibrainium-preview',
  };

  VibrainiumTab _activeTab = VibrainiumTab.workspace;
  int? _mainWin;
  int? _tabbarWin;
  int? _tabbarBuf;
  int? _tabbarNsId;

  VibrainiumBottomTab _activeBottomTab = VibrainiumBottomTab.problems;
  int? _bottomMainWin;
  int? _bottomTabbarWin;
  int? _bottomTabbarBuf;

  bool _isClosingLeftPanel = false;
  bool _isClosingBottomPanel = false;
  bool _isOpeningLeftTab = false;
  bool _isOpeningBottomTab = false;

  int? _lastActiveEditorWin;
  int? _lastSeenAlternateWin;
  bool _tabbarHighlightsInitialized = false;
  bool _winClosedAutocmdInitialized = false;
  int _currentSidebarWidth;
  int? _nvimPid;
  Timer? _saveStateDebounce;

  int get currentSidebarWidth => _currentSidebarWidth;

  Future<int> _resolveNvimPid() async {
    if (_nvimPid != null) return _nvimPid!;
    try {
      final pid = await nvim.execLua('return vim.fn.getpid()');
      if (pid is int) {
        _nvimPid = pid;
        return pid;
      }
    } catch (_) {}
    return -1;
  }

  void scheduleSaveWorkspaceState() {
    _saveStateDebounce?.cancel();
    _saveStateDebounce = Timer(const Duration(milliseconds: 500), () {
      saveWorkspaceState().catchError((_) {});
    });
  }

  /// Persists the file explorer and editor split tabs state to `.vibrainium/state.json`.
  Future<void> saveWorkspaceState() async {
    final root = workspaceSidebar.rootPath ?? await nvim.getCwd();
    final pid = await _resolveNvimPid();
    if (pid > 0) {
      if (WorkspaceStateLock.isHeldByOtherProcess(root, pid)) {
        return; // Another live Neovim process holds write ownership.
      }
      WorkspaceStateLock.tryAcquire(root, pid);
    }

    final explorerState = await workspaceSidebar.exportExplorerState();
    final currentWin = await nvim.getCurrentWin();
    final layout = await editorTabbar.exportLayout(root);

    // Resolve an active pane ID that is strictly an editor window, never a panel.
    String? activePaneId;
    if (await _isEditorCandidateWin(currentWin)) {
      activePaneId = 'win-$currentWin';
    } else if (await _isEditorCandidateWin(_lastActiveEditorWin)) {
      activePaneId = 'win-$_lastActiveEditorWin';
    } else if (layout != null) {
      final firstLeaf = _findFirstLeaf(layout);
      if (firstLeaf != null) {
        activePaneId = firstLeaf.id;
      }
    }

    final editorState = EditorState(
      activePaneId: activePaneId,
      layout: layout,
    );

    final state = VibrainiumWorkspaceState(
      explorer: explorerState,
      editor: editorState,
    );
    await state.saveAtomic(root);
  }

  static EditorLeafNode? _findFirstLeaf(EditorLayoutNode node) {
    if (node is EditorLeafNode) return node;
    if (node is EditorBranchNode) {
      for (final child in node.children) {
        final leaf = _findFirstLeaf(child);
        if (leaf != null) return leaf;
      }
    }
    return null;
  }

  /// Restores workspace tabs and explorer layout from `.vibrainium/state.json`.
  Future<void> restoreWorkspaceState() async {
    final root = workspaceSidebar.rootPath ?? await nvim.getCwd();
    final pid = await _resolveNvimPid();
    if (pid > 0 && !WorkspaceStateLock.isHeldByOtherProcess(root, pid)) {
      WorkspaceStateLock.tryAcquire(root, pid);
    }

    final stateFile = File(VibrainiumWorkspaceState.stateFilePath(root));
    if (!stateFile.existsSync()) {
      await openTab(VibrainiumTab.workspace);
      return;
    }

    final state = await VibrainiumWorkspaceState.load(root);

    // 1. Restore editor layout & tabs first so main editor windows exist
    if (state.editor.layout != null) {
      await _restoreEditorLayout(state.editor, root);
    }

    // 2. Restore explorer
    await workspaceSidebar.restoreExplorerState(
      state.explorer,
      openIfVisible: false,
    );
    if (state.explorer.isOpen) {
      await openTab(VibrainiumTab.workspace);
    } else {
      await close();
    }
  }

  Future<void> _restoreEditorLayout(
    EditorState editorState,
    String workspaceRoot,
  ) async {
    final layout = editorState.layout;
    if (layout == null) return;

    final allWins = await nvim.listWins();
    int? anchorWin;
    for (final w in allWins) {
      if (await _isEditorCandidateWin(w)) {
        anchorWin = w;
        break;
      }
    }
    anchorWin ??= await nvim.getCurrentWin();

    final leafWinMap = <String, int>{};

    Future<void> restoreNode(EditorLayoutNode node, int targetWin) async {
      if (node is EditorLeafNode) {
        leafWinMap[node.id] = targetWin;

        // 1. Add all openFiles to buffer list
        for (final rel in node.openFiles) {
          final abs =
              VibrainiumWorkspaceState.toAbsolutePath(workspaceRoot, rel);
          if (File(abs).existsSync()) {
            final escaped =
                abs.replaceAll(r'\', '/').replaceAll(' ', r'\ ');
            await nvim.command('badd $escaped');
          }
        }

        // 2. Open activeFile in targetWin
        if (node.activeFile != null) {
          final abs = VibrainiumWorkspaceState.toAbsolutePath(
              workspaceRoot, node.activeFile!);
          if (File(abs).existsSync()) {
            final escaped =
                abs.replaceAll(r'\', '/').replaceAll(' ', r'\ ');
            try {
              final bufId = await nvim.execLua(
                'return vim.fn.bufadd(...)',
                [abs],
              );
              if (bufId is int && bufId > 0) {
                await nvim.winSetBuf(targetWin, bufId);
              }
            } catch (_) {
              await nvim.setCurrentWin(targetWin);
              await nvim.command('edit $escaped');
            }
          }
        }

        // 3. Set dimensions if specified
        if (node.width != null && node.width! > 0) {
          try {
            await nvim.winSetWidth(targetWin, node.width!);
          } catch (_) {}
        }
        if (node.height != null && node.height! > 0) {
          try {
            await nvim.winSetHeight(targetWin, node.height!);
          } catch (_) {}
        }
        return;
      }

      if (node is EditorBranchNode) {
        final direction = node.type == 'row' ? 'right' : 'below';
        var curWin = targetWin;
        for (var i = 0; i < node.children.length; i++) {
          final child = node.children[i];
          if (i == 0) {
            await restoreNode(child, curWin);
          } else {
            final newWin = await nvim.openWin(0, true, {
              'win': curWin,
              'split': direction,
            });
            await restoreNode(child, newWin);
            curWin = newWin;
          }
        }
      }
    }

    await restoreNode(layout, anchorWin);

    final activeWin = leafWinMap[editorState.activePaneId];
    if (activeWin != null && await nvim.winIsValid(activeWin)) {
      await nvim.setCurrentWin(activeWin);
    }

    await editorTabbar.sync();
  }

  VibrainiumApp({
    required this.nvim,
    List<Vcs> vcsList = const [Git(), Svn()],
    this.sidebarWidth = 38,
    this.bottomPanelHeight = 12,
    this.socketPath,
    this.devPackagePath,
    this.onShutdown,
    ViffController? viff,
    WorkspaceSidebar? workspaceSidebar,
    VisearchPicker? searchPicker,
    ProblemsPanel? problemsPanel,
    AgentsPanel? agentsPanel,
  }) : _currentSidebarWidth = sidebarWidth {
    final sharedViff = viff ?? ViffController(nvim: nvim);
    this.viff = sharedViff;
    vcsSidebar = VivcsSidebar(
      nvim: nvim,
      vcsList: vcsList,
      sidebarWidth: sidebarWidth,
      extraKeymaps: _tabKeymaps,
      viff: sharedViff,
      bindRpc: false,
    );
    this.workspaceSidebar = workspaceSidebar ??
        WorkspaceSidebar(
          nvim: nvim,
          sidebarWidth: sidebarWidth,
          extraKeymaps: _tabKeymaps,
          viff: sharedViff,
          bindRpc: false,
        );
    this.problemsPanel = problemsPanel ??
        ProblemsPanel(
          nvim: nvim,
          panelHeight: bottomPanelHeight,
          extraKeymaps: _bottomTabKeymaps,
          onDiagnosticsUpdated: _renderBottomTabbar,
          bindRpc: false,
        );
    this.agentsPanel = agentsPanel ??
        AgentsPanel(
          nvim: nvim,
          panelHeight: bottomPanelHeight,
          treeWidth: sidebarWidth,
          extraKeymaps: _bottomTabKeymaps,
          socketPath: socketPath,
          devPackagePath: devPackagePath,
          onAgentsUpdated: _renderBottomTabbar,
          onRequestOpenPanel: () => openBottomTab(VibrainiumBottomTab.agents),
          viff: sharedViff,
          bindRpc: false,
        );
    this.searchPicker = searchPicker ?? VisearchPicker(nvim: nvim);
    bufferPreview = BufferPreviewManager(nvim: nvim);
    editorHome = EditorHomeView(
      nvim: nvim,
      getWorkspaceRoot: () async => this.workspaceSidebar.rootPath,
      getUncheckedInFiles: (root) async {
        final repos = vcsSidebar.repos.isNotEmpty
            ? vcsSidebar.repos
            : await discoverRepos(Directory(root), vcsSidebar.vcsList);
        final seen = <String>{};
        final out = <EditorHomeVcsFile>[];
        for (final repo in repos) {
          final status = await repo.vcs.status(repo.path);
          for (final item in [...status.staged, ...status.unstaged]) {
            final abs = '${repo.path.replaceAll(r'\', '/')}/${item.path}';
            if (!seen.add(abs)) continue;
            out.add(EditorHomeVcsFile(path: abs, statusCode: item.status.code));
          }
        }
        return out;
      },
    );
    editorTabbar = EditorTabbar(
      nvim: nvim,
      nonEditorFiletypes: _nonEditorFiletypes,
      isPanelWin: _isPanelWin,
      isPreviewWin: (w) => bufferPreview.isSplitPreviewWin(w),
      getPreviewTitle: (w) => bufferPreview.getPreviewTitle(w),
      getPreviewSourceBuf: (w) => bufferPreview.sourceBufForWin(w),
      onClosePreview: (w) => bufferPreview.closePreview(w),
      onShowEmptyHome: (win) => editorHome.showInWindow(win),
      onTabClosedPath: (path) => editorHome.recordRecentFile(path),
      onSync: () => editorHome.cleanupIfHidden(),
      onAddFileToChat: (filePath) =>
          this.agentsPanel.sendSelectionContext(filePath: filePath),
      onRevealInFinder: (filePath) => FileOps.revealInFinder(
        filePath,
        runProcess: this.workspaceSidebar.processRunner,
      ),
      onPreview: (winId, bufId) =>
          bufferPreview.openSplitPreview(targetWin: winId),
      onPreviewToggle: (winId, bufId) =>
          bufferPreview.toggleInPlace(targetWin: winId),
      onMarkdownPreview: (winId, bufId) =>
          bufferPreview.openSplitPreview(targetWin: winId),
      onMarkdownToggle: (winId, bufId) =>
          bufferPreview.toggleInPlace(targetWin: winId),
    );
    nvim.rpc.onRequest = _handleRpc;
    nvim.rpc.onNotification = (method, params) async {
      try {
        await _handleRpc(method, params);
      } catch (_) {}
    };
  }

  VibrainiumTab get activeTab => _activeTab;
  int? get mainWindowId => _mainWin;
  int? get tabbarWindowId => _tabbarWin;
  int? get tabbarBufferId => _tabbarBuf;

  VibrainiumBottomTab get activeBottomTab => _activeBottomTab;
  int? get bottomMainWindowId => _bottomMainWin;
  int? get bottomTabbarWindowId => _bottomTabbarWin;
  int? get bottomTabbarBufferId => _bottomTabbarBuf;

  bool _isLeftPanelWin(int win) =>
      win == _mainWin ||
      win == _tabbarWin ||
      win == workspaceSidebar.windowId ||
      win == workspaceSidebar.searchPrompt.windowId ||
      win == vcsSidebar.windowId;

  bool _isBottomPanelWin(int win) =>
      win == _bottomMainWin ||
      win == _bottomTabbarWin ||
      win == problemsPanel.windowId ||
      win == agentsPanel.windowId ||
      win == agentsPanel.treeWindowId ||
      win == agentsPanel.termWindowId;

  bool _isPanelWin(int win) =>
      _isLeftPanelWin(win) ||
      _isBottomPanelWin(win) ||
      win == viff.leftWindowId ||
      win == viff.rightWindowId ||
      win == searchPicker.paddingWindowId ||
      win == searchPicker.promptWindowId ||
      win == searchPicker.resultsWindowId ||
      win == searchPicker.previewWindowId ||
      bufferPreview.isSplitPreviewWin(win);

  Future<void> _ensureWinClosedAutocmd() async {
    if (_winClosedAutocmdInitialized) return;
    _winClosedAutocmdInitialized = true;
    try {
      await nvim.execLua('''
local grp = vim.api.nvim_create_augroup('VibrainiumPanelWinClosed', { clear = true })
vim.api.nvim_create_autocmd({ 'WinClosed' }, {
  group = grp,
  callback = function(args)
    local closed_win = tonumber(args.match)
    if closed_win and closed_win > 0 then
      pcall(function()
        require('vibrainium').action('win_closed', closed_win)
      end)
    end
  end,
})
''');
    } catch (_) {}
  }

  Future<void> _handleWinClosed(int win) async {
    if (!_isClosingLeftPanel && !_isOpeningLeftTab && _isLeftPanelWin(win)) {
      await close();
      return;
    }
    if (!_isClosingBottomPanel &&
        !_isOpeningBottomTab &&
        _isBottomPanelWin(win)) {
      await closeBottomPanel();
      return;
    }
    await _ensureSingleEditorPaneWhenPanelsOpen();
  }

  Future<void> _ensureSingleEditorPaneWhenPanelsOpen() async {
    try {
      final hasPanel = (_mainWin != null && await nvim.winIsValid(_mainWin!)) ||
          (_bottomMainWin != null && await nvim.winIsValid(_bottomMainWin!));
      if (!hasPanel) return;

      final allWins = await nvim.listWins();
      for (final w in allWins) {
        if (await _isEditorCandidateWin(w)) return;
      }

      int? newWin;
      if (_mainWin != null && await nvim.winIsValid(_mainWin!)) {
        final buf = await nvim.createBuf(listed: false, scratch: true);
        newWin = await nvim.openWin(buf, true, {
          'win': _mainWin!,
          'split': 'right',
        });
      } else if (_bottomMainWin != null &&
          await nvim.winIsValid(_bottomMainWin!)) {
        final buf = await nvim.createBuf(listed: false, scratch: true);
        newWin = await nvim.openWin(buf, true, {
          'win': _bottomMainWin!,
          'split': 'above',
        });
      }
      if (newWin != null && newWin > 0) {
        _lastActiveEditorWin = newWin;
        _syncAttachedWindows();
        await editorHome.showInWindow(newWin);
        await editorTabbar.sync();
      }
    } catch (_) {}
  }

  static bool isPanelFiletype(String ft) {
    if (ft.isEmpty || ft == EditorHomeView.homeFiletype) return false;
    if (_nonEditorFiletypes.contains(ft)) return true;
    return ft.startsWith('viworkspace') ||
        ft.startsWith('vivcs') ||
        ft.startsWith('viff') ||
        ft.startsWith('viproblems') ||
        ft.startsWith('viagent') ||
        ft.startsWith('visearch') ||
        ft.startsWith('vibrainium');
  }

  Future<bool> _isEditorCandidateWin(int? win) async {
    if (win == null || win <= 0 || _isPanelWin(win)) return false;
    try {
      if (!await nvim.winIsValid(win)) return false;
      final config = await nvim.winGetConfig(win);
      final relative = config['relative']?.toString() ?? '';
      if (relative.isNotEmpty) return false;
      final buf = await nvim.winGetBuf(win);
      if (buf > 0) {
        final ft = (await nvim.bufGetOption(buf, 'filetype'))?.toString() ?? '';
        if (ft == EditorHomeView.homeFiletype) return true;
        if (isPanelFiletype(ft)) return false;
        final bt = (await nvim.bufGetOption(buf, 'buftype'))?.toString() ?? '';
        if (bt.isNotEmpty) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Fallback anchor check for the bottom panel when no normal-file editor
  /// window exists (e.g. startup dashboard with `buftype=nofile` or a `viff`
  /// diff split). Rejects Vibrainium side/bottom panel windows and floating
  /// windows so the bottom panel never splits inside the left sidepanel.
  Future<bool> _isFallbackMainAnchorWin(int? win) async {
    if (win == null || win <= 0 || _isPanelWin(win)) return false;
    try {
      if (!await nvim.winIsValid(win)) return false;
      final config = await nvim.winGetConfig(win);
      final relative = config['relative']?.toString() ?? '';
      if (relative.isNotEmpty) return false;
      final buf = await nvim.winGetBuf(win);
      if (buf > 0) {
        final ft = (await nvim.bufGetOption(buf, 'filetype'))?.toString() ?? '';
        if (ft != 'viff' && isPanelFiletype(ft)) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _rememberActiveEditorWin() async {
    try {
      final currentWin = await nvim.getCurrentWin();
      final altWin = await nvim.getAlternateWin();
      if (await _isEditorCandidateWin(currentWin)) {
        _lastActiveEditorWin = currentWin;
        _lastSeenAlternateWin = altWin;
        return;
      }
      if (await _isEditorCandidateWin(altWin)) {
        if (_lastActiveEditorWin == null ||
            !await _isEditorCandidateWin(_lastActiveEditorWin) ||
            (_lastSeenAlternateWin != null && altWin != _lastSeenAlternateWin)) {
          _lastActiveEditorWin = altWin;
        }
        _lastSeenAlternateWin = altWin;
      }
    } catch (_) {}
  }

  Future<bool> isOpen() async {
    final win = _mainWin;
    if (win == null) return false;
    return nvim.winIsValid(win);
  }

  Future<bool> isBottomPanelOpen() async {
    final win = _bottomMainWin;
    if (win == null) return false;
    return nvim.winIsValid(win);
  }

  Future<void> openTab(VibrainiumTab tab) async {
    _isOpeningLeftTab = true;
    try {
      await _ensureWinClosedAutocmd();
      await _rememberActiveEditorWin();

      await vcsSidebar.closeModals();
      await workspaceSidebar.closeModals();
      await editorTabbar.closeModals();
      _activeTab = tab;

      final targetBuf = tab == VibrainiumTab.workspace
          ? await workspaceSidebar.ensureBuffer()
          : await vcsSidebar.ensureBuffer();

      if (!await isOpen()) {
        _mainWin = null;
        await workspaceSidebar.closeSearchWin();
        final staleTabWin = _tabbarWin;
        _tabbarWin = null;
        if (staleTabWin != null && await nvim.winIsValid(staleTabWin)) {
          try {
            if ((await nvim.listWins()).length > 1) {
              await nvim.winClose(staleTabWin, force: true);
            }
          } catch (_) {}
        }
        await _cleanupStaleSidepanelWins();
        final mainWin = await nvim.openWin(targetBuf, true, {
          'win': -1,
          'split': 'left',
          'width': _currentSidebarWidth,
          'style': 'minimal',
        });
        _mainWin = mainWin;
        await _configureMainWin(mainWin);
        if (await isBottomPanelOpen() &&
            _activeBottomTab == VibrainiumBottomTab.agents) {
          await agentsPanel.syncTerminalSplit(focusTerminal: false);
        }
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
        await workspaceSidebar.ensureSearchWin();
        _syncAttachedWindows();
        await workspaceSidebar.ensureAutoSync();
        await workspaceSidebar.refresh();
        await workspaceSidebar.syncActiveFile(focusSidebar: false);
      } else {
        await workspaceSidebar.closeSearchWin();
        _syncAttachedWindows();
        await vcsSidebar.refresh(rescanRepos: vcsSidebar.repos.isEmpty);
      }
      await editorTabbar.sync();
    } finally {
      _isOpeningLeftTab = false;
    }
  }

  Future<void> toggleLeftPanel() async {
    if (await isOpen()) {
      await close();
    } else {
      await openTab(_activeTab);
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

  Future<void> updateSidebarWidth(
    int newWidth, {
    bool syncWindow = false,
  }) async {
    if (newWidth <= 0) return;
    _currentSidebarWidth = newWidth;
    workspaceSidebar.sidebarWidth = newWidth;
    vcsSidebar.sidebarWidth = newWidth;
    if (syncWindow) {
      final mainWin = _mainWin;
      if (mainWin != null && await nvim.winIsValid(mainWin)) {
        await nvim.winSetWidth(mainWin, newWidth);
      }
    }
    if (await isOpen()) {
      await _renderTabbar();
    }
  }

  Future<void> _syncSidebarLayout() async {
    final mainWin = _mainWin;
    if (mainWin != null && await nvim.winIsValid(mainWin)) {
      final actualWidth = await nvim.winGetWidth(mainWin);
      if (actualWidth > 0 && actualWidth != _currentSidebarWidth) {
        _currentSidebarWidth = actualWidth;
        workspaceSidebar.sidebarWidth = actualWidth;
        vcsSidebar.sidebarWidth = actualWidth;
        await _renderTabbar();
      }
    }
  }

  Future<void> handleTabbarClick() async {
    final tabWin = _tabbarWin;
    if (tabWin == null || !await nvim.winIsValid(tabWin)) return;

    int? clickedCol;
    try {
      final mouse = await nvim.getMousePos();
      if (mouse != null && mouse.winId == tabWin && mouse.column > 0) {
        clickedCol = mouse.column - 1;
      }
    } catch (_) {}
    final col = clickedCol ?? (await nvim.winGetCursor(tabWin)).$2;
    final wsBytes = utf8.encode(_wsTabLabel).length;
    final sepBytes = utf8.encode(_tabSeparator).length;

    if (col < wsBytes) {
      await openTab(VibrainiumTab.workspace);
    } else if (col >= wsBytes + sepBytes) {
      await openTab(VibrainiumTab.vcs);
    }
    final mainWin = _mainWin;
    if (mainWin != null && await nvim.winIsValid(mainWin)) {
      await nvim.setCurrentWin(mainWin);
    }
  }

  Future<bool> _routeCrossWindowTabbarClick() async {
    final tabWin = _tabbarWin;
    final bottomTabWin = _bottomTabbarWin;
    try {
      final mouse = await nvim.getMousePos();
      if (mouse != null && mouse.winId > 0) {
        if (tabWin != null &&
            mouse.winId == tabWin &&
            await nvim.winIsValid(tabWin)) {
          await handleTabbarClick();
          return true;
        }
        if (bottomTabWin != null &&
            mouse.winId == bottomTabWin &&
            await nvim.winIsValid(bottomTabWin)) {
          await handleBottomTabbarClick();
          return true;
        }
        return false;
      }
    } catch (_) {}

    final curWin = await nvim.getCurrentWin();
    if (tabWin != null && curWin == tabWin && await nvim.winIsValid(tabWin)) {
      await handleTabbarClick();
      return true;
    }
    if (bottomTabWin != null &&
        curWin == bottomTabWin &&
        await nvim.winIsValid(bottomTabWin)) {
      await handleBottomTabbarClick();
      return true;
    }
    return false;
  }

  /// Redirects focus away from the 1-line sidebar/bottom-panel tabbar splits
  /// when `<C-w>` pane navigation lands on them, or handles mouse clicks that
  /// entered the tabbar split from another window.
  Future<void> handlePanelTabbarWinEnter({String? trigger}) async {
    final curWin = await nvim.getCurrentWin();
    if (curWin == _tabbarWin) {
      if (trigger != 'key') {
        try {
          final mouse = await nvim.getMousePos();
          if (mouse != null &&
              mouse.winId == _tabbarWin &&
              mouse.column > 0) {
            await handleTabbarClick();
            return;
          }
        } catch (_) {}
      }
      final altWin = await nvim.getAlternateWin();
      if (altWin == _mainWin && await isBottomPanelOpen()) {
        await nvim.setCurrentWin(_bottomMainWin!);
        return;
      }
      if (_mainWin != null && await nvim.winIsValid(_mainWin!)) {
        await nvim.setCurrentWin(_mainWin!);
      }
      return;
    }
    if (curWin == _bottomTabbarWin) {
      if (trigger != 'key') {
        try {
          final mouse = await nvim.getMousePos();
          if (mouse != null &&
              mouse.winId == _bottomTabbarWin &&
              mouse.column > 0) {
            await handleBottomTabbarClick();
            return;
          }
        } catch (_) {}
      }
      if (_bottomMainWin != null && await nvim.winIsValid(_bottomMainWin!)) {
        await nvim.setCurrentWin(_bottomMainWin!);
      }
    }
  }

  Future<void> openBottomTab(VibrainiumBottomTab tab) async {
    _isOpeningBottomTab = true;
    try {
      await _ensureWinClosedAutocmd();
      await _rememberActiveEditorWin();

      await problemsPanel.closeModals();
      await agentsPanel.closeModals();
      await editorTabbar.closeModals();
      if (tab != VibrainiumBottomTab.agents) {
        await agentsPanel.closeTerminalSplit();
      }
      _activeBottomTab = tab;

      final targetBuf = tab == VibrainiumBottomTab.problems
          ? await problemsPanel.ensureBuffer()
          : await agentsPanel.ensureBuffer();

      if (!await isBottomPanelOpen()) {
        await _cleanupStaleBottomPanelWins();
        int? anchorWin = _lastActiveEditorWin ??
            workspaceSidebar.lastActiveEditorWin ??
            vcsSidebar.lastActiveEditorWin ??
            problemsPanel.lastActiveEditorWin ??
            agentsPanel.lastActiveEditorWin;
        if (anchorWin != null && !await _isEditorCandidateWin(anchorWin)) {
          anchorWin = null;
        }
        List<int>? wins;
        if (anchorWin == null) {
          wins = await nvim.listWins();
          for (final w in wins) {
            if (await _isEditorCandidateWin(w)) {
              anchorWin = w;
              break;
            }
          }
        }
        if (anchorWin == null) {
          wins ??= await nvim.listWins();
          final fallbackCandidates = <int?>[
            viff.rightWindowId,
            _lastActiveEditorWin,
            await nvim.getAlternateWin(),
            ...wins,
          ];
          for (final candidate in fallbackCandidates) {
            if (await _isFallbackMainAnchorWin(candidate)) {
              anchorWin = candidate;
              break;
            }
          }
        }
        if (anchorWin == null &&
            _mainWin != null &&
            await nvim.winIsValid(_mainWin!)) {
          final emptyBuf = await nvim.createBuf(listed: true, scratch: false);
          anchorWin = await nvim.openWin(emptyBuf, false, {
            'win': _mainWin!,
            'split': 'right',
          });
          _lastActiveEditorWin ??= anchorWin;
        }

        final bottomWin = await nvim.openWin(targetBuf, true, {
          if (anchorWin != null) 'win': anchorWin,
          'split': 'below',
          'height': bottomPanelHeight,
          'style': 'minimal',
        });
        _bottomMainWin = bottomWin;
        await _configureBottomMainWin(bottomWin);
      } else {
        final bottomWin = _bottomMainWin!;
        await nvim.winSetBuf(bottomWin, targetBuf);
        await _configureBottomMainWin(bottomWin);
        await nvim.setCurrentWin(bottomWin);
      }

      await _ensureBottomTabbarWin();
      _syncAttachedWindows();

      if (tab == VibrainiumBottomTab.problems) {
        await problemsPanel.ensureAutoRefresh();
        await problemsPanel.refresh();
      } else {
        await agentsPanel.syncTerminalSplit(focusTerminal: false);
        _syncAttachedWindows();
        await agentsPanel.refresh();
      }

      await _renderBottomTabbar();
      await editorTabbar.sync();
    } finally {
      _isOpeningBottomTab = false;
    }
  }

  Future<void> toggleBottomPanel() async {
    if (await isBottomPanelOpen()) {
      await closeBottomPanel();
    } else {
      await openBottomTab(_activeBottomTab);
    }
  }

  Future<void> toggleBottomTab(VibrainiumBottomTab tab) async {
    if (await isBottomPanelOpen()) {
      if (_activeBottomTab == tab) {
        await closeBottomPanel();
      } else {
        await openBottomTab(tab);
      }
    } else {
      await openBottomTab(tab);
    }
  }

  Future<void> cycleBottomTab(int delta) async {
    const values = VibrainiumBottomTab.values;
    final nextIdx = (_activeBottomTab.index + delta) % values.length;
    final resolvedIdx = nextIdx < 0 ? nextIdx + values.length : nextIdx;
    await openBottomTab(values[resolvedIdx]);
  }

  Future<void> handleBottomTabbarClick() async {
    final tabWin = _bottomTabbarWin;
    if (tabWin == null || !await nvim.winIsValid(tabWin)) return;

    int? clickedCol;
    try {
      final mouse = await nvim.getMousePos();
      if (mouse != null && mouse.winId == tabWin && mouse.column > 0) {
        clickedCol = mouse.column - 1;
      }
    } catch (_) {}
    final col = clickedCol ?? (await nvim.winGetCursor(tabWin)).$2;

    final probBytes = utf8.encode(_buildProblemsTabLabel()).length;
    final sepBytes = utf8.encode(_tabSeparator).length;
    final agentsBytes = utf8.encode(_buildAgentsTabLabel()).length;

    if (col < probBytes) {
      await openBottomTab(VibrainiumBottomTab.problems);
    } else if (col >= probBytes + sepBytes &&
        col < probBytes + sepBytes + agentsBytes) {
      await openBottomTab(VibrainiumBottomTab.agents);
    }
    final bottomWin = _bottomMainWin;
    if (bottomWin != null && await nvim.winIsValid(bottomWin)) {
      await nvim.setCurrentWin(bottomWin);
    }
  }

  Future<void> closeBottomPanel() async {
    if (_isClosingBottomPanel) return;
    _isClosingBottomPanel = true;
    try {
      await problemsPanel.closeModals();
      await agentsPanel.closeModals();
      await editorTabbar.closeModals();
      await agentsPanel.closeTerminalSplit();
      problemsPanel.attachWindow(null);
      agentsPanel.attachWindow(null);

      final tabWin = _bottomTabbarWin;
      _bottomTabbarWin = null;
      if (tabWin != null && await nvim.winIsValid(tabWin)) {
        await nvim.winClose(tabWin, force: true);
      }

      final bottomWin = _bottomMainWin;
      _bottomMainWin = null;
      if (bottomWin != null && await nvim.winIsValid(bottomWin)) {
        await nvim.winClose(bottomWin, force: true);
      }

      _syncAttachedWindows();
    } finally {
      _isClosingBottomPanel = false;
    }
  }

  Future<void> close() async {
    if (_isClosingLeftPanel) return;
    _isClosingLeftPanel = true;
    try {
      await vcsSidebar.closeModals();
      await workspaceSidebar.closeModals();
      await workspaceSidebar.closeSearchWin();
      await editorTabbar.closeModals();
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

      if (await isBottomPanelOpen() &&
          _activeBottomTab == VibrainiumBottomTab.agents) {
        await agentsPanel.syncTerminalSplit(focusTerminal: false);
      }

      _syncAttachedWindows();
    } finally {
      _isClosingLeftPanel = false;
    }
  }

  Future<void> onHotReloaded() async {
    _tabbarHighlightsInitialized = false;
    _winClosedAutocmdInitialized = false;
    await _ensureWinClosedAutocmd();
    editorTabbar.resetForHotReload();
    await vcsSidebar.onHotReloaded();
    await workspaceSidebar.onHotReloaded();
    await problemsPanel.onHotReloaded();
    await agentsPanel.onHotReloaded();
    await searchPicker.onHotReloaded();

    final tabBuf = _tabbarBuf;
    if (tabBuf != null && await nvim.bufIsValid(tabBuf)) {
      await _bindTabbarKeys(tabBuf);
    }
    if (await isOpen()) {
      await _ensureTabbarWin();
      _syncAttachedWindows();
      await _renderTabbar();
    }

    final bottomTabBuf = _bottomTabbarBuf;
    if (bottomTabBuf != null && await nvim.bufIsValid(bottomTabBuf)) {
      await _bindBottomTabbarKeys(bottomTabBuf);
    }
    if (await isBottomPanelOpen()) {
      await _ensureBottomTabbarWin();
      _syncAttachedWindows();
      await _renderBottomTabbar();
    }
    await _ensureTabbarHighlights();
    await editorTabbar.sync();
  }

  Future<void> _cleanupStaleSidepanelWins() async {
    final wins = await nvim.listWins();
    for (final w in wins) {
      if (_isPanelWin(w)) continue;
      final buf = await nvim.winGetBuf(w);
      if (buf <= 0) continue;
      final ft = (await nvim.bufGetOption(buf, 'filetype'))?.toString() ?? '';
      if (ft == 'viworkspace' ||
          ft == 'viworkspace-search' ||
          ft == 'vivcs' ||
          ft == 'vibrainium-tabbar') {
        try {
          if (await nvim.winIsValid(w) && (await nvim.listWins()).length > 1) {
            await nvim.winClose(w, force: true);
          }
        } catch (_) {}
      }
    }
  }

  Future<void> _cleanupStaleBottomPanelWins() async {
    final wins = await nvim.listWins();
    for (final w in wins) {
      if (_isPanelWin(w)) continue;
      final buf = await nvim.winGetBuf(w);
      if (buf <= 0) continue;
      final ft = (await nvim.bufGetOption(buf, 'filetype'))?.toString() ?? '';
      if (ft == 'viproblems' ||
          ft == 'viagent' ||
          ft == 'viagent-term' ||
          ft == 'vibrainium-bottom-tabbar') {
        try {
          if (await nvim.winIsValid(w) && (await nvim.listWins()).length > 1) {
            await nvim.winClose(w, force: true);
          }
        } catch (_) {}
      }
    }
  }

  void _syncAttachedWindows() {
    final excluded = <int>{
      if (_mainWin != null) _mainWin!,
      if (_tabbarWin != null) _tabbarWin!,
      if (workspaceSidebar.searchPrompt.windowId != null)
        workspaceSidebar.searchPrompt.windowId!,
      if (_bottomMainWin != null) _bottomMainWin!,
      if (_bottomTabbarWin != null) _bottomTabbarWin!,
      if (agentsPanel.termWindowId != null) agentsPanel.termWindowId!,
    };
    final activeEditor = _lastActiveEditorWin ??
        workspaceSidebar.lastActiveEditorWin ??
        vcsSidebar.lastActiveEditorWin ??
        problemsPanel.lastActiveEditorWin ??
        agentsPanel.lastActiveEditorWin ??
        searchPicker.lastActiveEditorWin;
    workspaceSidebar.attachWindow(
      _activeTab == VibrainiumTab.workspace ? _mainWin : null,
      excludedWins: excluded,
      lastActiveEditorWin: activeEditor,
    );
    vcsSidebar.attachWindow(
      _activeTab == VibrainiumTab.vcs ? _mainWin : null,
      excludedWins: excluded,
      lastActiveEditorWin: activeEditor,
    );
    problemsPanel.attachWindow(
      _activeBottomTab == VibrainiumBottomTab.problems ? _bottomMainWin : null,
      excludedWins: excluded,
      lastActiveEditorWin: activeEditor,
    );
    agentsPanel.attachWindow(
      _activeBottomTab == VibrainiumBottomTab.agents ? _bottomMainWin : null,
      excludedWins: excluded,
      lastActiveEditorWin: activeEditor,
    );
    searchPicker.attachWindow(
      excludedWins: excluded,
      lastActiveEditorWin: activeEditor,
    );
    viff.updateWindowContext(
      excludedWins: excluded,
      lastActiveEditorWin: activeEditor,
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
    await nvim.winSetOption(win, 'scrolloff', 0);
    await nvim.winSetOption(win, 'sidescrolloff', 0);
    await nvim.winSetOption(win, 'winfixwidth', true);
  }

  Future<void> _configureBottomMainWin(int win) async {
    await nvim.winSetOption(win, 'number', false);
    await nvim.winSetOption(win, 'relativenumber', false);
    await nvim.winSetOption(win, 'signcolumn', 'no');
    await nvim.winSetOption(win, 'foldcolumn', '0');
    await nvim.winSetOption(win, 'statuscolumn', '');
    await nvim.winSetOption(win, 'wrap', false);
    await nvim.winSetOption(win, 'cursorline', true);
    await nvim.winSetOption(win, 'scrolloff', 0);
    await nvim.winSetOption(win, 'sidescrolloff', 0);
    await nvim.winSetOption(win, 'winfixheight', true);
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

  Future<void> _ensureBottomTabbarWin() async {
    final bottomWin = _bottomMainWin;
    if (bottomWin == null || !await nvim.winIsValid(bottomWin)) return;

    await _ensureTabbarHighlights();

    var buf = _bottomTabbarBuf;
    if (buf == null || !await nvim.bufIsValid(buf)) {
      buf = await nvim.createBuf(listed: false, scratch: true);
      _bottomTabbarBuf = buf;
      await nvim.bufSetOption(buf, 'buftype', 'nofile');
      await nvim.bufSetOption(buf, 'bufhidden', 'hide');
      await nvim.bufSetOption(buf, 'swapfile', false);
      await nvim.bufSetOption(buf, 'filetype', 'vibrainium-bottom-tabbar');
    }
    await _bindBottomTabbarKeys(buf);

    final existingWin = _bottomTabbarWin;
    if (existingWin == null || !await nvim.winIsValid(existingWin)) {
      final tabWin = await nvim.openWin(buf, false, {
        'win': bottomWin,
        'split': 'below',
        'height': 1,
        'style': 'minimal',
      });
      _bottomTabbarWin = tabWin;
      await nvim.winSetOption(tabWin, 'number', false);
      await nvim.winSetOption(tabWin, 'relativenumber', false);
      await nvim.winSetOption(tabWin, 'signcolumn', 'no');
      await nvim.winSetOption(tabWin, 'foldcolumn', '0');
      await nvim.winSetOption(tabWin, 'statuscolumn', '');
      await nvim.winSetOption(tabWin, 'wrap', false);
      await nvim.winSetOption(tabWin, 'cursorline', false);
      await nvim.winSetOption(tabWin, 'winfixheight', true);
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

  Future<void> _bindBottomTabbarKeys(int buf) async {
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<LeftMouse>',
      "<LeftMouse><Cmd>lua require('vibrainium').action('bottom_tab.click')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<LeftRelease>',
      "<LeftRelease><Cmd>lua require('vibrainium').action('bottom_tab.click')<CR>",
    );
    const mappings = <String, String>{
      '<CR>': 'bottom_tab.click',
      'q': 'problems.close',
      'H': 'reload',
      ..._bottomTabKeymaps,
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
    final usedChars =
        wsLabel.runes.length + sep.runes.length + vcsCore.runes.length;
    final width = _currentSidebarWidth;
    final padCount = (width - usedChars).clamp(0, width);
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

  String _buildProblemsTabLabel() {
    final errors = problemsPanel.errorCount;
    final warnings = problemsPanel.warnCount;
    final infos = problemsPanel.infoCount;
    final hints = problemsPanel.hintCount;
    if (errors > 0 || warnings > 0) {
      return ' 󰅚 Problems (󰅚 $errors 󰀪 $warnings) [3] ';
    }
    if (infos > 0 || hints > 0) {
      return ' 󰅚 Problems (${infos + hints}) [3] ';
    }
    return ' 󰅚 Problems [3] ';
  }

  String _buildAgentsTabLabel() {
    final chats = agentsPanel.chatCount;
    final files = agentsPanel.totalChangedFilesCount;
    if (chats > 0 && files > 0) {
      return ' 󰚩 Agents ($chats • 󰈙 $files) [4] ';
    }
    if (chats > 0) {
      return ' 󰚩 Agents ($chats) [4] ';
    }
    return ' 󰚩 Agents [4] ';
  }

  Future<void> _renderBottomTabbar() async {
    final buf = _bottomTabbarBuf;
    final nsId = _tabbarNsId;
    if (buf == null || nsId == null || !await nvim.bufIsValid(buf)) return;

    final problemsLabel = _buildProblemsTabLabel();
    final agentsLabel = _buildAgentsTabLabel();
    const sep = _tabSeparator;
    var totalWidth = 80;
    try {
      totalWidth = await nvim.getEditorWidth();
    } catch (_) {}

    final usedChars = problemsLabel.runes.length +
        sep.runes.length +
        agentsLabel.runes.length +
        sep.runes.length;
    final padCount = (totalWidth - usedChars).clamp(0, totalWidth);
    final trailingFill = ' ' * padCount;
    final line = '$problemsLabel$sep$agentsLabel$sep$trailingFill';

    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetLines(buf, lines: [line]);
    await nvim.bufSetOption(buf, 'modifiable', false);

    final probBytes = utf8.encode(problemsLabel).length;
    final sepBytes = utf8.encode(sep).length;
    final agentsBytes = utf8.encode(agentsLabel).length;
    final fillBytes = utf8.encode(trailingFill).length;

    final probGroup = _activeBottomTab == VibrainiumBottomTab.problems
        ? 'VibrainiumTabActive'
        : 'VibrainiumTabInactive';
    final agentsGroup = _activeBottomTab == VibrainiumBottomTab.agents
        ? 'VibrainiumTabActive'
        : 'VibrainiumTabInactive';

    await nvim.bufClearNamespace(buf, nsId);
    await nvim.bufSetExtmark(buf, nsId, 0, 0, {
      'end_col': probBytes,
      'hl_group': probGroup,
    });
    await nvim.bufSetExtmark(buf, nsId, 0, probBytes, {
      'end_col': probBytes + sepBytes,
      'hl_group': 'VibrainiumTabSeparator',
    });
    final agentsStart = probBytes + sepBytes;
    final agentsEnd = agentsStart + agentsBytes;
    await nvim.bufSetExtmark(buf, nsId, 0, agentsStart, {
      'end_col': agentsEnd,
      'hl_group': agentsGroup,
    });
    await nvim.bufSetExtmark(buf, nsId, 0, agentsEnd, {
      'end_col': agentsEnd + sepBytes,
      'hl_group': 'VibrainiumTabSeparator',
    });
    if (fillBytes > 0) {
      await nvim.bufSetExtmark(buf, nsId, 0, agentsEnd + sepBytes, {
        'end_col': agentsEnd + sepBytes + fillBytes,
        'hl_group': 'VibrainiumTabInactive',
      });
    }
  }

  Future<Object?> _handleRpc(String method, List<Object?> params) async {
    if (method == 'vibrainium_shutdown') {
      try {
        await bufferPreview.closeAllPreviews();
      } catch (_) {}
      if (onShutdown != null) {
        await onShutdown!();
      }
      return true;
    }
    if (method == 'vibrainium_agent_hook' && params.length >= 3) {
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
      if (parsed != null) {
        await agentsPanel.handleHookEvent(parsed);
      }
      return true;
    }

    final action = (method == 'vibrainium_action' ||
                method == 'vivcs_action' ||
                method == 'viproblems_action' ||
                method == 'viagent_action') &&
            params.isNotEmpty
        ? params.first.toString()
        : method;

    if (action.startsWith('editor_tab.menu_select:')) {
      final idx = int.tryParse(action.substring('editor_tab.menu_select:'.length));
      if (idx != null) {
        await editorTabbar.contextMenu.selectIndex(idx);
      }
      return true;
    }

    switch (action) {
      case 'win_closed':
        final closedWin = params.length > 1
            ? int.tryParse(params[1]?.toString() ?? '')
            : null;
        if (closedWin != null) {
          await _handleWinClosed(closedWin);
        }
        return true;
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
      case 'workspace.save_state':
        await saveWorkspaceState();
        if (_nvimPid != null) {
          final root = workspaceSidebar.rootPath ?? await nvim.getCwd();
          WorkspaceStateLock.release(root, _nvimPid!);
        }
        return true;
      case 'workspace.restore_state':
        await restoreWorkspaceState();
        return true;
      case 'tab.vcs':
      case 'open':
      case 'vcs.open':
        await openTab(VibrainiumTab.vcs);
        return true;
      case 'left_panel.toggle':
      case 'panel.toggle_left':
        await toggleLeftPanel();
        return true;
      case 'bottom_panel.toggle':
      case 'panel.toggle_bottom':
        await toggleBottomPanel();
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
      case 'bottom_tab.click':
        await handleBottomTabbarClick();
        return true;
      case 'bottom_tab.next':
        await cycleBottomTab(1);
        return true;
      case 'bottom_tab.prev':
        await cycleBottomTab(-1);
        return true;
      case 'bottom_tab.problems':
      case 'problems.open':
        await openBottomTab(VibrainiumBottomTab.problems);
        return true;
      case 'problems.toggle':
        await toggleBottomTab(VibrainiumBottomTab.problems);
        return true;
      case 'problems.close':
        await closeBottomPanel();
        return true;
      case 'bottom_tab.agents':
      case 'agent.open':
      case 'agents.open':
        await openBottomTab(VibrainiumBottomTab.agents);
        return true;
      case 'agent.toggle':
      case 'agents.toggle':
        await toggleBottomTab(VibrainiumBottomTab.agents);
        return true;
      case 'agent.close':
      case 'agents.close':
        await closeBottomPanel();
        return true;
      case 'panel_tabbar.win_enter':
        final trigger = params.length > 1 ? params[1]?.toString() : null;
        await handlePanelTabbarWinEnter(trigger: trigger);
        return true;
      case 'workspace.click':
      case 'workspace.double_click':
      case 'vcs.click':
      case 'vcs.double_click':
      case 'click':
      case 'double_click':
      case 'problems.click':
      case 'problems.double_click':
      case 'agent.click':
      case 'agent.double_click':
      case 'agents.click':
      case 'agents.double_click':
      case 'viff.click':
        if (await _routeCrossWindowTabbarClick()) {
          return true;
        }
        break;
      case 'editor_tab.sync':
      case 'buffer.sync':
      case 'buffer.scroll':
        await _rememberActiveEditorWin();
        await _syncSidebarLayout();
        await _ensureTabbarHighlights();
        await bufferPreview.pruneStaleSessions();
        await editorTabbar.sync();
        await bufferPreview.syncAll();
        scheduleSaveWorkspaceState();
        return true;
      case 'buffer.change':
        final raw = params.isNotEmpty ? params[0] : null;
        final bufId = raw is int ? raw : (raw is String ? int.tryParse(raw.trim()) : null);
        if (bufId != null && bufId > 0) {
          await bufferPreview.onSourceBufferChanged(bufId);
        }
        return true;
      case 'workspace.resize':
      case 'sidebar.resize':
      case 'panel.resize_left':
        final raw = params.length > 1
            ? params[1]
            : (params.isNotEmpty ? params[0] : null);
        final targetWidth = raw is int
            ? raw
            : (raw is String ? int.tryParse(raw.trim()) : null);
        if (targetWidth != null && targetWidth > 0) {
          await updateSidebarWidth(targetWidth, syncWindow: true);
        }
        return true;
      case 'editor_tab.click':
        await _ensureTabbarHighlights();
        final winId = params.length > 1 ? int.tryParse(params[1].toString()) ?? 0 : 0;
        final bufId = params.length > 2 ? int.tryParse(params[2].toString()) ?? 0 : 0;
        final button = params.length > 3 ? params[3].toString() : 'l';
        final screenRow = params.length > 4 ? int.tryParse(params[4].toString()) : null;
        final screenCol = params.length > 5 ? int.tryParse(params[5].toString()) : null;
        await editorTabbar.selectTab(
          winId,
          bufId,
          button: button,
          screenRow: screenRow,
          screenCol: screenCol,
        );
        if (winId > 0 && !_isPanelWin(winId) && button != 'r') {
          _lastActiveEditorWin = winId;
          _syncAttachedWindows();
        }
        return true;
      case 'editor_tab.right_click':
        await _ensureTabbarHighlights();
        final winId = params.length > 1 ? int.tryParse(params[1].toString()) ?? 0 : 0;
        final winCol = params.length > 2 ? int.tryParse(params[2].toString()) ?? 1 : 1;
        final screenRow = params.length > 3 ? int.tryParse(params[3].toString()) : null;
        final screenCol = params.length > 4 ? int.tryParse(params[4].toString()) : null;
        await editorTabbar.handleRightClick(
          winId: winId,
          winCol: winCol,
          screenRow: screenRow,
          screenCol: screenCol,
        );
        return true;
      case 'editor_tab.context_menu':
      case 'buffer.menu':
        await _rememberActiveEditorWin();
        await _ensureTabbarHighlights();
        final winId = params.length > 1 ? int.tryParse(params[1].toString()) : null;
        final bufId = params.length > 2 ? int.tryParse(params[2].toString()) : null;
        final screenRow = params.length > 3 ? int.tryParse(params[3].toString()) : null;
        final screenCol = params.length > 4 ? int.tryParse(params[4].toString()) : null;
        await editorTabbar.openContextMenu(
          winId: winId,
          bufId: bufId,
          screenRow: screenRow,
          screenCol: screenCol,
          fallbackEditorWin: _lastActiveEditorWin,
        );
        return true;
      case 'editor_tab.menu_click':
        await editorTabbar.contextMenu.handleClick();
        return true;
      case 'editor_tab.menu_confirm':
        await editorTabbar.contextMenu.confirm();
        return true;
      case 'editor_tab.menu_right':
        await editorTabbar.contextMenu.handleRightKey();
        return true;
      case 'editor_tab.menu_back':
        await editorTabbar.contextMenu.handleBack();
        return true;
      case 'editor_tab.menu_close':
        final expectedBuf = params.length > 1
            ? int.tryParse(params[1]?.toString() ?? '')
            : null;
        await editorTabbar.contextMenu.cancel(expectedBufId: expectedBuf);
        return true;
      case 'editor_tab.split_up':
      case 'buffer.split_up':
        await _rememberActiveEditorWin();
        await _ensureTabbarHighlights();
        await editorTabbar.splitTab(
          direction: 'above',
          fallbackEditorWin: _lastActiveEditorWin,
        );
        return true;
      case 'editor_tab.split_down':
      case 'buffer.split_down':
        await _rememberActiveEditorWin();
        await _ensureTabbarHighlights();
        await editorTabbar.splitTab(
          direction: 'below',
          fallbackEditorWin: _lastActiveEditorWin,
        );
        return true;
      case 'editor_tab.split_left':
      case 'buffer.split_left':
        await _rememberActiveEditorWin();
        await _ensureTabbarHighlights();
        await editorTabbar.splitTab(
          direction: 'left',
          fallbackEditorWin: _lastActiveEditorWin,
        );
        return true;
      case 'editor_tab.split_right':
      case 'buffer.split_right':
        await _rememberActiveEditorWin();
        await _ensureTabbarHighlights();
        await editorTabbar.splitTab(
          direction: 'right',
          fallbackEditorWin: _lastActiveEditorWin,
        );
        return true;
      case 'editor_tab.close':
      case 'buffer.close':
        await _rememberActiveEditorWin();
        await _ensureTabbarHighlights();
        final winId = params.length > 1 ? int.tryParse(params[1].toString()) : null;
        final bufId = params.length > 2 ? int.tryParse(params[2].toString()) : null;
        await editorTabbar.closeTab(
          winId: winId,
          bufId: bufId,
          fallbackEditorWin: _lastActiveEditorWin,
        );
        return true;
      case 'editor_tab.close_others':
      case 'buffer.close_others':
      case 'buffer.closeothers':
        await _rememberActiveEditorWin();
        await _ensureTabbarHighlights();
        final winId = params.length > 1 ? int.tryParse(params[1].toString()) : null;
        final bufId = params.length > 2 ? int.tryParse(params[2].toString()) : null;
        await editorTabbar.closeOtherTabs(
          winId: winId,
          bufId: bufId,
          fallbackEditorWin: _lastActiveEditorWin,
        );
        return true;
      case 'editor_tab.close_right':
      case 'buffer.close_right':
      case 'buffer.closeright':
        await _rememberActiveEditorWin();
        await _ensureTabbarHighlights();
        final winId = params.length > 1 ? int.tryParse(params[1].toString()) : null;
        final bufId = params.length > 2 ? int.tryParse(params[2].toString()) : null;
        await editorTabbar.closeTabsToRight(
          winId: winId,
          bufId: bufId,
          fallbackEditorWin: _lastActiveEditorWin,
        );
        return true;
      case 'editor_tab.close_all':
      case 'buffer.close_all':
      case 'buffer.closeall':
        await _rememberActiveEditorWin();
        await _ensureTabbarHighlights();
        final winId = params.length > 1 ? int.tryParse(params[1].toString()) : null;
        await editorTabbar.closeAllTabs(
          winId: winId,
          fallbackEditorWin: _lastActiveEditorWin,
        );
        return true;
      case 'editor_tab.copy_path':
      case 'buffer.copy_path':
      case 'buffer.copypath':
        await _rememberActiveEditorWin();
        await editorTabbar.copyTabPath(
          fallbackEditorWin: _lastActiveEditorWin,
        );
        return true;
      case 'editor_tab.reveal':
      case 'buffer.reveal':
        await _rememberActiveEditorWin();
        await editorTabbar.revealTabInFinder(
          fallbackEditorWin: _lastActiveEditorWin,
        );
        return true;
      case 'editor_tab.next':
      case 'buffer.next':
        await _rememberActiveEditorWin();
        await _ensureTabbarHighlights();
        await editorTabbar.cycleTab(1, fallbackEditorWin: _lastActiveEditorWin);
        return true;
      case 'editor_tab.prev':
      case 'buffer.prev':
        await _rememberActiveEditorWin();
        await _ensureTabbarHighlights();
        await editorTabbar.cycleTab(-1, fallbackEditorWin: _lastActiveEditorWin);
        return true;
      case 'buffer.preview':
      case 'buffer.preview_toggle':
      case 'markdown.toggle':
        await bufferPreview.toggleInPlace();
        await editorTabbar.sync();
        await bufferPreview.syncAll(immediate: true);
        return true;
      case 'buffer.preview_split':
      case 'markdown.preview':
        await bufferPreview.openSplitPreview();
        await editorTabbar.sync();
        await bufferPreview.syncAll(immediate: true);
        return true;
      case 'buffer.preview_close':
      case 'markdown.close':
        await bufferPreview.closeAllPreviews();
        await editorTabbar.sync();
        return true;
      case 'reload':
        await bufferPreview.closeAllPreviews();
        final res = await vcsSidebar.handleAction(action, params);
        await workspaceSidebar.onHotReloaded();
        await problemsPanel.onHotReloaded();
        await agentsPanel.onHotReloaded();
        await searchPicker.onHotReloaded();
        _tabbarHighlightsInitialized = false;
        editorTabbar.resetForHotReload();
        final tabBuf = _tabbarBuf;
        if (tabBuf != null && await nvim.bufIsValid(tabBuf)) {
          await _bindTabbarKeys(tabBuf);
        }
        if (await isOpen()) {
          await _ensureTabbarWin();
          _syncAttachedWindows();
          await _renderTabbar();
        }
        final bottomTabBuf = _bottomTabbarBuf;
        if (bottomTabBuf != null && await nvim.bufIsValid(bottomTabBuf)) {
          await _bindBottomTabbarKeys(bottomTabBuf);
        }
        if (await isBottomPanelOpen()) {
          await _ensureBottomTabbarWin();
          _syncAttachedWindows();
          await _renderBottomTabbar();
        }
        await _ensureTabbarHighlights();
        await editorTabbar.sync();
        return res;
    }

    await _rememberActiveEditorWin();
    _syncAttachedWindows();

    if (action.startsWith('viff.') || action.startsWith('diff.')) {
      final res = await viff.handleAction(action, params);
      final updatedWin = viff.rightWindowId;
      if (updatedWin != null && updatedWin > 0 && !_isPanelWin(updatedWin)) {
        _lastActiveEditorWin = updatedWin;
        _syncAttachedWindows();
      }
      return res;
    }
    if (action.startsWith('agent.') || action.startsWith('agents.')) {
      final res = await agentsPanel.handleAction(action, params);
      final updatedWin = agentsPanel.lastActiveEditorWin;
      if (updatedWin != null && updatedWin > 0 && !_isPanelWin(updatedWin)) {
        _lastActiveEditorWin = updatedWin;
        _syncAttachedWindows();
      }
      await _ensureTabbarHighlights();
      await editorTabbar.sync();
      scheduleSaveWorkspaceState();
      return res;
    }
    if (action.startsWith('problems.')) {
      final res = await problemsPanel.handleAction(action);
      final updatedWin = problemsPanel.lastActiveEditorWin;
      if (updatedWin != null && updatedWin > 0 && !_isPanelWin(updatedWin)) {
        _lastActiveEditorWin = updatedWin;
        _syncAttachedWindows();
      }
      await _ensureTabbarHighlights();
      await editorTabbar.sync();
      scheduleSaveWorkspaceState();
      return res;
    }
    if (action.startsWith('home.')) {
      await editorHome.handleAction(
        action,
        onOpenFile: (filePath, targetWin) async {
          if (targetWin != null && await nvim.winIsValid(targetWin)) {
            await nvim.setCurrentWin(targetWin);
          }
          final escaped =
              filePath.replaceAll(r'\', '/').replaceAll(' ', r'\ ');
          await nvim.command('edit $escaped');
          await editorHome.cleanupIfHidden();
          await workspaceSidebar.syncActiveFile(
            filePath: filePath,
            editorWin: targetWin,
            focusSidebar: false,
          );
          await _ensureTabbarHighlights();
          await editorTabbar.sync();
          scheduleSaveWorkspaceState();
        },
        onTriggerSearch: (searchAction) async {
          await _handleRpc(searchAction, const <Object?>[]);
        },
      );
      return null;
    }
    if (action.startsWith('search.')) {
      final res = await searchPicker.handleAction(action, params);
      final pickerWin = searchPicker.lastActiveEditorWin;
      if (pickerWin != null && pickerWin > 0 && !_isPanelWin(pickerWin)) {
        _lastActiveEditorWin = pickerWin;
        _syncAttachedWindows();
      }
      if ((action == 'search.confirm' ||
              action == 'search.results_double_click' ||
              action == 'search.results_click') &&
          !await searchPicker.isOpen() &&
          searchPicker.lastConfirmedFilePath != null) {
        await workspaceSidebar.syncActiveFile(
          filePath: searchPicker.lastConfirmedFilePath,
          editorWin: _lastActiveEditorWin,
          focusSidebar: false,
        );
        final updatedWin = workspaceSidebar.lastActiveEditorWin;
        if (updatedWin != null && updatedWin > 0 && !_isPanelWin(updatedWin)) {
          _lastActiveEditorWin = updatedWin;
          _syncAttachedWindows();
        }
        await _ensureTabbarHighlights();
        await editorTabbar.sync();
      }
      return res;
    }
    if (action.startsWith('workspace.')) {
      final res = await workspaceSidebar.handleAction(action, params);
      final updatedWin = workspaceSidebar.lastActiveEditorWin;
      if (updatedWin != null && updatedWin > 0 && !_isPanelWin(updatedWin)) {
        _lastActiveEditorWin = updatedWin;
        _syncAttachedWindows();
      }
      await _ensureTabbarHighlights();
      await editorTabbar.sync();
      scheduleSaveWorkspaceState();
      return res;
    }
    final res = await vcsSidebar.handleAction(action, params);
    final updatedWin = vcsSidebar.lastActiveEditorWin;
    if (updatedWin != null && updatedWin > 0 && !_isPanelWin(updatedWin)) {
      _lastActiveEditorWin = updatedWin;
      _syncAttachedWindows();
    }
    return res;
  }
}
