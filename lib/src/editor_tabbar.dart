import 'package:nvim/nvim.dart';
import 'package:visettings/visettings.dart';

import 'editor_home.dart';

/// A single entry in [EditorTabContextMenu].
class EditorTabMenuItem extends NvimContextMenuItem {
  const EditorTabMenuItem({
    required super.label,
    required super.shortcut,
    super.isSubmenu = false,
    required super.onSelect,
  });
}

/// Floating context menu (and cascading submenu) for file items in [EditorTabbar].
class EditorTabContextMenu extends NvimContextMenu<EditorTabMenuItem> {
  EditorTabContextMenu(Nvim nvim)
    : super(
        nvim: nvim,
        actionPrefix: 'editor_tab',
        filetype: 'vibrainium-tab-menu',
        augroupName: 'VibrainiumEditorTabMenu',
        cancelOnOutsideClick: true,
      );

  Future<void> open({
    required List<EditorTabMenuItem> items,
    String title = 'Tab Actions',
    int? row,
    int? col,
    Map<String, int> extraMnemonics = const {},
    Future<void> Function()? onBack,
    Future<void> Function()? onCancel,
  }) => openMenu(
    items: items,
    title: title,
    row: row,
    col: col,
    minWidth: 24,
    maxWidth: 48,
    padding: 6,
    clampToEditor: true,
    bindRightArrowSubmenu: true,
    extraMnemonics: extraMnemonics,
    onBack: onBack,
    onCancel: onCancel,
  );
}

/// Manages independent per-split editor file tabbars using Neovim's window-local
/// `winbar` option so `<C-w>` pane navigation never lands on a tabbar window.
class EditorTabbar {
  final Nvim nvim;
  final Set<String> nonEditorFiletypes;
  final bool Function(int win) isPanelWin;
  final Future<void> Function(String filePath)? onAddFileToChat;
  final Future<void> Function(String filePath)? onRevealInFinder;
  final Future<void> Function(int winId, int bufId)? onPreview;
  final Future<void> Function(int winId, int bufId)? onPreviewToggle;
  final Future<void> Function(int winId, int bufId)? onMarkdownPreview;
  final Future<void> Function(int winId, int bufId)? onMarkdownToggle;
  final bool Function(int win)? isPreviewWin;
  final String? Function(int win)? getPreviewTitle;
  final int? Function(int win)? getPreviewSourceBuf;
  final Future<void> Function(int win)? onClosePreview;
  final Future<void> Function(int win)? onShowEmptyHome;
  final void Function(String path)? onTabClosedPath;
  final Future<void> Function()? onSync;

  late final EditorTabContextMenu contextMenu = EditorTabContextMenu(nvim);

  final Map<int, List<int>> _winTabs = {};
  final Map<int, int> _winActiveBuf = {};
  final Map<int, String> _lastWinbar = {};
  final Map<int, List<_TabColumnSpan>> _winTabSpans = {};
  bool _initialized = false;

  EditorTabbar({
    required this.nvim,
    required this.nonEditorFiletypes,
    required this.isPanelWin,
    this.onAddFileToChat,
    this.onRevealInFinder,
    this.onPreview,
    this.onPreviewToggle,
    this.onMarkdownPreview,
    this.onMarkdownToggle,
    this.isPreviewWin,
    this.getPreviewTitle,
    this.getPreviewSourceBuf,
    this.onClosePreview,
    this.onShowEmptyHome,
    this.onTabClosedPath,
    this.onSync,
  });

  /// Returns an unmodifiable view of the open buffer IDs for editor window [win].
  List<int> tabsForWindow(int win) =>
      List.unmodifiable(_winTabs[win] ?? const <int>[]);

  /// Returns the active buffer ID tracked for editor window [win], or `null`.
  int? activeBufferForWindow(int win) => _winActiveBuf[win];

  /// Resolves which buffer tab is at 1-based window column [winCol1Based] in [win]'s `winbar`.
  int? resolveTabAtColumn(int win, int winCol1Based) {
    final spans = _winTabSpans[win];
    if (spans != null && spans.isNotEmpty) {
      for (final s in spans) {
        if (winCol1Based >= s.startCol && winCol1Based <= s.endCol) {
          return s.buf;
        }
      }
    }
    return _winActiveBuf[win] ??
        ((_winTabs[win]?.isNotEmpty ?? false) ? _winTabs[win]!.first : null);
  }

  /// Exports an [EditorLeafNode] representation of editor window [win] for session persistence.
  Future<EditorLeafNode?> exportPaneForWindow(
    int win,
    String workspaceRoot,
  ) async {
    if (!await _isEditorWin(win)) return null;
    final tabs = _winTabs[win] ?? const <int>[];
    final activeBuf = _winActiveBuf[win] ??
        (await nvim.winIsValid(win) ? await nvim.winGetBuf(win) : null);
    final openFiles = <String>[];
    String? activeFilePath;

    for (final b in tabs) {
      if (await _isTrackableFileBuf(b)) {
        final name = await nvim.bufGetName(b);
        if (name.trim().isNotEmpty) {
          final rel = VibrainiumWorkspaceState.toRelativePath(workspaceRoot, name);
          if (!openFiles.contains(rel)) {
            openFiles.add(rel);
          }
          if (b == activeBuf) {
            activeFilePath = rel;
          }
        }
      }
    }

    if (activeFilePath == null &&
        activeBuf != null &&
        await _isTrackableFileBuf(activeBuf)) {
      final name = await nvim.bufGetName(activeBuf);
      if (name.trim().isNotEmpty) {
        final rel = VibrainiumWorkspaceState.toRelativePath(workspaceRoot, name);
        if (!openFiles.contains(rel)) {
          openFiles.add(rel);
        }
        activeFilePath = rel;
      }
    }

    int? width;
    int? height;
    try {
      width = await nvim.winGetWidth(win);
      height = await nvim.winGetHeight(win);
    } catch (_) {}

    if (openFiles.isEmpty && activeFilePath == null) {
      return null;
    }

    return EditorLeafNode(
      id: 'win-$win',
      width: width,
      height: height,
      openFiles: List.unmodifiable(openFiles),
      activeFile: activeFilePath,
    );
  }

  /// Recursively parses Neovim's `winlayout()` AST and prunes non-editor windows,
  /// returning an [EditorLayoutNode] representing the editor pane layout.
  Future<EditorLayoutNode?> exportLayout(String workspaceRoot) async {
    try {
      final raw = await nvim.execLua('return vim.fn.winlayout()');
      return await _parseRawLayout(raw, workspaceRoot);
    } catch (_) {
      return null;
    }
  }

  Future<EditorLayoutNode?> _parseRawLayout(
    Object? raw,
    String workspaceRoot,
  ) async {
    if (raw is! List || raw.length < 2) return null;
    final type = raw[0]?.toString();
    if (type == 'leaf') {
      final win = raw[1];
      if (win is int && await _isEditorWin(win)) {
        return exportPaneForWindow(win, workspaceRoot);
      }
      return null;
    }
    if (type == 'row' || type == 'col') {
      final rawChildren = raw[1];
      if (rawChildren is List) {
        final children = <EditorLayoutNode>[];
        for (final c in rawChildren) {
          final parsed = await _parseRawLayout(c, workspaceRoot);
          if (parsed != null) {
            children.add(parsed);
          }
        }
        if (children.isEmpty) return null;
        if (children.length == 1) return children.first;
        return EditorBranchNode(
          type: type == 'col' ? 'col' : 'row',
          children: children,
        );
      }
    }
    return null;
  }

  void resetForHotReload() {
    _initialized = false;
    _lastWinbar.clear();
    nvim.resetRightMouseRouterForHotReload();
  }

  Future<void> closeModals() async {
    await contextMenu.close();
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    await nvim.ensureRightMouseRouter();
    try {
      await nvim.execLua('''
_G.VibrainiumWinbarSelect = function(minwid, _clicks, button, _modifiers)
  local pos = vim.fn.getmousepos()
  local winid = (pos and pos.winid and pos.winid > 0) and pos.winid or vim.api.nvim_get_current_win()
  local srow = (pos and pos.screenrow and pos.screenrow > 0) and pos.screenrow or 1
  local scol = (pos and pos.screencol and pos.screencol > 0) and pos.screencol or 1
  require('vibrainium').action('editor_tab.click', winid, minwid, button or 'l', srow, scol)
end

_G.VibrainiumWinbarClose = function(minwid, _clicks, _button, _modifiers)
  local pos = vim.fn.getmousepos()
  local winid = (pos and pos.winid and pos.winid > 0) and pos.winid or vim.api.nvim_get_current_win()
  require('vibrainium').action('editor_tab.close', winid, minwid)
end

local function disable_global_tabline()
  pcall(vim.api.nvim_del_augroup_by_name, 'BufferLine')
  pcall(vim.api.nvim_del_augroup_by_name, 'BufferLineCmd')
  pcall(vim.api.nvim_del_augroup_by_name, 'BufferlineCmds')
  _G.nvim_bufferline = function()
    vim.o.tabline = ''
    vim.o.showtabline = 0
    return ''
  end
  vim.o.tabline = ''
  vim.o.showtabline = 0
end

disable_global_tabline()

local grp = vim.api.nvim_create_augroup('VibrainiumEditorTabbarSync', { clear = true })
local pending = false
vim.api.nvim_create_autocmd({ 'BufAdd', 'BufEnter', 'WinEnter', 'BufWinEnter', 'BufModifiedSet', 'BufDelete', 'BufWipeout', 'WinClosed', 'WinResized' }, {
  group = grp,
  callback = function()
    disable_global_tabline()
    if pending then
      return
    end
    pending = true
    vim.schedule(function()
      pending = false
      disable_global_tabline()
      pcall(function()
        require('vibrainium').action('editor_tab.sync')
      end)
    end)
  end,
})
''');
    } catch (_) {}
  }

  Future<void> _enforceHiddenGlobalTabline() async {
    try {
      await nvim.setOption('tabline', '');
      await nvim.setOption('showtabline', 0);
    } catch (_) {}
  }

  bool _isPanelFiletype(String ft) {
    if (ft.isEmpty) return false;
    if (ft == EditorHomeView.homeFiletype) return false;
    if (nonEditorFiletypes.contains(ft)) return true;
    return ft.startsWith('viworkspace') ||
        ft.startsWith('vivcs') ||
        ft.startsWith('viff') ||
        ft.startsWith('viproblems') ||
        ft.startsWith('viagent') ||
        ft.startsWith('visearch') ||
        ft.startsWith('vibrainium');
  }

  Future<bool> _isEditorWin(int win) async {
    if (win <= 0) return false;
    if (isPreviewWin?.call(win) ?? false) return true;
    if (isPanelWin(win)) return false;
    try {
      if (!await nvim.winIsValid(win)) return false;
      final config = await nvim.winGetConfig(win);
      final relative = config['relative']?.toString() ?? '';
      if (relative.isNotEmpty) return false;
      final buf = await nvim.winGetBuf(win);
      if (buf > 0) {
        final ft = (await nvim.bufGetOption(buf, 'filetype'))?.toString() ?? '';
        if (ft == 'vibrainium-preview' ||
            ft == EditorHomeView.homeFiletype ||
            (isPreviewWin?.call(win) ?? false)) {
          return true;
        }
        if (_isPanelFiletype(ft)) return false;
        final bt = (await nvim.bufGetOption(buf, 'buftype'))?.toString() ?? '';
        if (bt.isNotEmpty) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isTrackableFileBuf(int buf) async {
    if (buf <= 0) return false;
    try {
      if (!await nvim.bufIsValid(buf)) return false;
      final bt = (await nvim.bufGetOption(buf, 'buftype'))?.toString() ?? '';
      if (bt.isNotEmpty) return false;
      final ft = (await nvim.bufGetOption(buf, 'filetype'))?.toString() ?? '';
      if (ft == EditorHomeView.homeFiletype || _isPanelFiletype(ft)) return false;
      final name = (await nvim.bufGetName(buf)).trim();
      if (name.isEmpty) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _applyWinbar(int win, String winbar) async {
    if (_lastWinbar[win] == winbar) {
      try {
        final res = await nvim.rpc.request(
          'nvim_get_option_value',
          [
            'winbar',
            {'win': win},
          ],
        );
        final current = res?.toString() ?? '';
        if (current == winbar) return;
      } catch (_) {
        return;
      }
    }
    _lastWinbar[win] = winbar;
    await nvim.winSetOption(win, 'winbar', winbar);
  }

  /// Synchronizes per-split tab lists with current Neovim windows/buffers and
  /// updates each editor window's `winbar`.
  Future<void> sync() async {
    await _ensureInitialized();
    await _enforceHiddenGlobalTabline();
    await onSync?.call();

    final allWins = await nvim.listWins();
    final validWinSet = allWins.toSet();

    // Remove closed windows.
    _winTabs.removeWhere((w, _) => !validWinSet.contains(w));
    _winActiveBuf.removeWhere((w, _) => !validWinSet.contains(w));
    _lastWinbar.removeWhere((w, _) => !validWinSet.contains(w));
    _winTabSpans.removeWhere((w, _) => !validWinSet.contains(w));

    final editorWins = <int>[];
    for (final win in allWins) {
      if (await _isEditorWin(win)) {
        editorWins.add(win);
      }
    }

    // Validate existing buffers and record current buffer per editor split.
    final validBufCache = <int, bool>{};
    Future<bool> checkBuf(int b) async {
      if (validBufCache.containsKey(b)) return validBufCache[b]!;
      final ok = await _isTrackableFileBuf(b);
      validBufCache[b] = ok;
      return ok;
    }

    for (final win in editorWins) {
      final existing = _winTabs.putIfAbsent(win, () => <int>[]);
      final filtered = <int>[];
      for (final b in existing) {
        if (await checkBuf(b) && !filtered.contains(b)) {
          filtered.add(b);
        }
      }
      existing
        ..clear()
        ..addAll(filtered);

      final curBuf = await nvim.winGetBuf(win);
      final effectiveBuf = getPreviewSourceBuf?.call(win) ?? curBuf;
      if (await checkBuf(effectiveBuf)) {
        if (!existing.contains(effectiveBuf)) {
          existing.add(effectiveBuf);
        }
        _winActiveBuf[win] = effectiveBuf;
      } else if (existing.isEmpty) {
        _winActiveBuf.remove(win);
      } else if (!_winActiveBuf.containsKey(win) ||
          !existing.contains(_winActiveBuf[win])) {
        _winActiveBuf[win] = existing.last;
      }
    }

    // Collect metadata for all tracked buffers across editor splits.
    final bufPaths = <int, String>{};
    final bufModified = <int, bool>{};
    for (final win in editorWins) {
      for (final buf in _winTabs[win] ?? const <int>[]) {
        if (!bufPaths.containsKey(buf)) {
          bufPaths[buf] = await nvim.bufGetName(buf);
          final mod = await nvim.bufGetOption(buf, 'modified');
          bufModified[buf] = mod == true;
        }
      }
    }

    for (final win in editorWins) {
      if (isPreviewWin?.call(win) == true) {
        final title = getPreviewTitle?.call(win) ?? '󰍔 Preview';
        final winbar = '%#VibrainiumTabActive# $title %#VibrainiumTabClose#%@VibrainiumWinbarClose@✕%X%*';
        await _applyWinbar(win, winbar);
        continue;
      }
      final tabs = _winTabs[win] ?? const <int>[];
      if (tabs.isEmpty) {
        _winTabSpans.remove(win);
        await _applyWinbar(win, '');
        continue;
      }
      final activeBuf = _winActiveBuf[win] ?? tabs.first;
      var winWidth = 80;
      try {
        winWidth = await nvim.winGetWidth(win);
      } catch (_) {}

      final (winbar, spans) = _buildWinbarString(
        tabs: tabs,
        activeBuf: activeBuf,
        bufPaths: bufPaths,
        bufModified: bufModified,
        maxWidth: winWidth,
      );
      _winTabSpans[win] = spans;
      await _applyWinbar(win, winbar);
    }
  }

  /// Handles a mouse click on a tab in [winId] for buffer [bufId].
  /// Left click (`'l'`) switches to that tab in [winId]; middle click (`'m'`) closes it;
  /// right click (`'r'`) opens the tab context menu.
  Future<void> selectTab(
    int winId,
    int bufId, {
    String button = 'l',
    int? screenRow,
    int? screenCol,
  }) async {
    if (button == 'm') {
      await closeTab(winId: winId, bufId: bufId);
      return;
    }
    if (button == 'r') {
      await openContextMenu(
        winId: winId,
        bufId: bufId,
        screenRow: screenRow,
        screenCol: screenCol,
      );
      return;
    }
    if (winId <= 0 || !await nvim.winIsValid(winId)) return;
    if (bufId <= 0 || !await nvim.bufIsValid(bufId)) {
      await sync();
      return;
    }
    final tabs = _winTabs.putIfAbsent(winId, () => <int>[]);
    if (!tabs.contains(bufId)) {
      tabs.add(bufId);
    }
    _winActiveBuf[winId] = bufId;
    await nvim.setCurrentWin(winId);
    await nvim.winSetBuf(winId, bufId);
    await sync();
  }

  /// Handles a `<RightMouse>` click on the `winbar` row (`line == 0`) of [winId] at [winCol].
  Future<void> handleRightClick({
    required int winId,
    required int winCol,
    int? screenRow,
    int? screenCol,
  }) async {
    if (!await _isEditorWin(winId)) return;
    await sync();
    final bufId = resolveTabAtColumn(winId, winCol);
    if (bufId == null || bufId <= 0) return;
    await openContextMenu(
      winId: winId,
      bufId: bufId,
      screenRow: screenRow,
      screenCol: screenCol,
    );
  }

  /// Opens the context menu for tab [bufId] in editor split [winId].
  Future<void> openContextMenu({
    int? winId,
    int? bufId,
    int? screenRow,
    int? screenCol,
    int? fallbackEditorWin,
  }) async {
    final targetWin = await _resolveTargetEditorWin(winId, fallbackEditorWin);
    if (targetWin == null) return;

    await sync();
    final tabs = _winTabs[targetWin] ?? const <int>[];
    final currentBuf = await nvim.winGetBuf(targetWin);
    final targetBuf = (bufId != null && bufId > 0 && await nvim.bufIsValid(bufId))
        ? bufId
        : (_winActiveBuf[targetWin] ??
            (tabs.isNotEmpty ? tabs.first : currentBuf));
    if (targetBuf <= 0 || !await nvim.bufIsValid(targetBuf)) return;

    final rawPath = (await nvim.bufGetName(targetBuf)).trim();
    if (rawPath.isEmpty) return;
    final normPath = _normalizePath(rawPath);
    final title = _basename(normPath);

    var menuRow = screenRow;
    var menuCol = screenCol != null ? (screenCol - 1).clamp(0, 10000) : null;
    if (menuRow == null || menuCol == null) {
      try {
        final mouse = await nvim.getMousePos();
        if (mouse != null && mouse.screenRow > 0 && mouse.screenCol > 0) {
          menuRow ??= mouse.screenRow;
          menuCol ??= (mouse.screenCol - 1).clamp(0, 10000);
        }
      } catch (_) {}
    }
    if (menuRow == null || menuCol == null) {
      try {
        final (winRow0, winCol0) = await nvim.winGetPosition(targetWin);
        menuRow ??= winRow0 + 1;
        menuCol ??= winCol0 + 2;
      } catch (_) {
        menuRow ??= 1;
        menuCol ??= 2;
      }
    }

    Future<void> restoreEditorFocus() async {
      if (await nvim.winIsValid(targetWin)) {
        await nvim.setCurrentWin(targetWin);
      }
    }

    final items = <EditorTabMenuItem>[
      EditorTabMenuItem(
        label: 'Copy Path',
        shortcut: 'y',
        onSelect: () async {
          await nvim.copyToClipboard(normPath);
          await nvim.notify('Copied path: $normPath');
          await restoreEditorFocus();
        },
      ),
      EditorTabMenuItem(
        label: 'Add File to Chat',
        shortcut: 'a',
        onSelect: () async {
          await restoreEditorFocus();
          if (onAddFileToChat != null) {
            await onAddFileToChat!(normPath);
          }
        },
      ),
      EditorTabMenuItem(
        label: 'Reveal in Finder',
        shortcut: 'f',
        onSelect: () async {
          await restoreEditorFocus();
          if (onRevealInFinder != null) {
            try {
              await onRevealInFinder!(normPath);
            } catch (e) {
              await nvim.notify('Reveal in Finder failed: $e', level: 4);
            }
          }
        },
      ),
      if (_isPreviewablePath(normPath)) ...[
        if (onPreview != null || onMarkdownPreview != null)
          EditorTabMenuItem(
            label: 'Preview in Split',
            shortcut: 'p',
            onSelect: () async {
              await restoreEditorFocus();
              final fn = onPreview ?? onMarkdownPreview;
              if (fn != null) await fn(targetWin, targetBuf);
            },
          ),
        if (onPreviewToggle != null || onMarkdownToggle != null)
          EditorTabMenuItem(
            label: 'Toggle Render Mode',
            shortcut: 't',
            onSelect: () async {
              await restoreEditorFocus();
              final fn = onPreviewToggle ?? onMarkdownToggle;
              if (fn != null) await fn(targetWin, targetBuf);
            },
          ),
      ],
      EditorTabMenuItem(
        label: 'Split',
        shortcut: 's ▸',
        isSubmenu: true,
        onSelect: () async {
          await openSplitSubmenu(
            winId: targetWin,
            bufId: targetBuf,
            title: title,
            row: menuRow!,
            col: menuCol!,
          );
        },
      ),
      EditorTabMenuItem(
        label: 'Close Others',
        shortcut: 'o',
        onSelect: () async {
          await restoreEditorFocus();
          await closeOtherTabs(winId: targetWin, bufId: targetBuf);
        },
      ),
      EditorTabMenuItem(
        label: 'Close to the Right',
        shortcut: 'r',
        onSelect: () async {
          await restoreEditorFocus();
          await closeTabsToRight(winId: targetWin, bufId: targetBuf);
        },
      ),
      EditorTabMenuItem(
        label: 'Close All',
        shortcut: 'x',
        onSelect: () async {
          await restoreEditorFocus();
          await closeAllTabs(winId: targetWin);
        },
      ),
    ];

    final mnemonics = <String, int>{};
    for (var i = 0; i < items.length; i++) {
      final shortcutKey = items[i].shortcut.trim().split(' ').first.toLowerCase();
      if (shortcutKey.isNotEmpty) {
        mnemonics[shortcutKey] = i;
      }
    }

    await contextMenu.open(
      items: items,
      title: title,
      row: menuRow,
      col: menuCol,
      extraMnemonics: mnemonics,
      onCancel: restoreEditorFocus,
    );
  }

  /// Opens the VS Code-style `Split` submenu (`Split Up`, `Split Down`, `Split Left`, `Split Right`).
  Future<void> openSplitSubmenu({
    required int winId,
    required int bufId,
    required String title,
    required int row,
    required int col,
  }) async {
    Future<void> restoreEditorFocus() async {
      if (await nvim.winIsValid(winId)) {
        await nvim.setCurrentWin(winId);
      }
    }

    Future<void> reopenMainMenu() async {
      await openContextMenu(
        winId: winId,
        bufId: bufId,
        screenRow: row,
        screenCol: col + 1,
      );
    }

    final splitItems = <EditorTabMenuItem>[
      EditorTabMenuItem(
        label: 'Split Up',
        shortcut: 'k',
        onSelect: () async {
          await splitTab(winId: winId, bufId: bufId, direction: 'above');
        },
      ),
      EditorTabMenuItem(
        label: 'Split Down',
        shortcut: 'j',
        onSelect: () async {
          await splitTab(winId: winId, bufId: bufId, direction: 'below');
        },
      ),
      EditorTabMenuItem(
        label: 'Split Left',
        shortcut: 'h',
        onSelect: () async {
          await splitTab(winId: winId, bufId: bufId, direction: 'left');
        },
      ),
      EditorTabMenuItem(
        label: 'Split Right',
        shortcut: 'l',
        onSelect: () async {
          await splitTab(winId: winId, bufId: bufId, direction: 'right');
        },
      ),
      EditorTabMenuItem(
        label: '← Back',
        shortcut: '<BS>',
        onSelect: reopenMainMenu,
      ),
    ];

    await contextMenu.open(
      items: splitItems,
      title: '$title — Split',
      row: row,
      col: col,
      onBack: reopenMainMenu,
      onCancel: restoreEditorFocus,
    );
  }

  /// Splits editor window [winId] in [direction] (`'above'`, `'below'`, `'left'`, `'right'`)
  /// displaying buffer [bufId], and initializes the new split's independent tabbar.
  Future<int?> splitTab({
    int? winId,
    int? bufId,
    required String direction,
    int? fallbackEditorWin,
  }) async {
    final targetWin = await _resolveTargetEditorWin(winId, fallbackEditorWin);
    if (targetWin == null) return null;

    final currentBuf = await nvim.winGetBuf(targetWin);
    final targetBuf = (bufId != null && bufId > 0 && await nvim.bufIsValid(bufId))
        ? bufId
        : (_winActiveBuf[targetWin] ?? currentBuf);
    if (targetBuf <= 0 || !await nvim.bufIsValid(targetBuf)) return null;

    final newWin = await nvim.openWin(targetBuf, true, {
      'win': targetWin,
      'split': direction,
    });
    _winTabs[newWin] = <int>[targetBuf];
    _winActiveBuf[newWin] = targetBuf;
    await sync();
    return newWin;
  }

  /// Closes [bufId] (or the active buffer) in editor split [winId] (or current editor split).
  /// Other splits keep their own tabs untouched.
  Future<void> closeTab({
    int? winId,
    int? bufId,
    int? fallbackEditorWin,
  }) async {
    final targetWin = await _resolveTargetEditorWin(winId, fallbackEditorWin);
    if (targetWin == null) return;

    if (isPreviewWin?.call(targetWin) == true) {
      if (onClosePreview != null) {
        await onClosePreview!(targetWin);
      }
      return;
    }

    final tabs = _winTabs[targetWin];
    if (tabs == null || tabs.isEmpty) return;

    final currentBuf = await nvim.winGetBuf(targetWin);
    final targetBuf = (bufId != null && bufId > 0) ? bufId : currentBuf;
    final idx = tabs.indexOf(targetBuf);
    if (idx < 0) return;

    if (onTabClosedPath != null) {
      try {
        final closedName = (await nvim.bufGetName(targetBuf)).trim();
        if (closedName.isNotEmpty) {
          onTabClosedPath!(closedName);
        }
      } catch (_) {}
    }

    tabs.removeAt(idx);

    if (currentBuf == targetBuf) {
      if (tabs.isNotEmpty) {
        final nextIdx = idx < tabs.length ? idx : tabs.length - 1;
        final nextBuf = tabs[nextIdx];
        _winActiveBuf[targetWin] = nextBuf;
        await nvim.winSetBuf(targetWin, nextBuf);
      } else {
        await _handleEmptyEditorPane(targetWin);
      }
    } else if (_winActiveBuf[targetWin] == targetBuf) {
      _winActiveBuf[targetWin] =
          tabs.contains(currentBuf) ? currentBuf : (tabs.isNotEmpty ? tabs.last : 0);
      if (_winActiveBuf[targetWin] == 0) {
        _winActiveBuf.remove(targetWin);
      }
    }

    await sync();
  }

  /// Closes all tabs except [bufId] (or the active buffer) in editor split [winId].
  /// Other splits keep their own tabs untouched.
  Future<void> closeOtherTabs({
    int? winId,
    int? bufId,
    int? fallbackEditorWin,
  }) async {
    final targetWin = await _resolveTargetEditorWin(winId, fallbackEditorWin);
    if (targetWin == null) return;

    await sync();
    final tabs = _winTabs[targetWin];
    if (tabs == null || tabs.isEmpty) return;

    final currentBuf = await nvim.winGetBuf(targetWin);
    final targetBuf = (bufId != null && bufId > 0 && tabs.contains(bufId))
        ? bufId
        : (_winActiveBuf[targetWin] ?? currentBuf);
    if (!tabs.contains(targetBuf)) return;

    tabs
      ..clear()
      ..add(targetBuf);
    _winActiveBuf[targetWin] = targetBuf;
    if (currentBuf != targetBuf) {
      await nvim.winSetBuf(targetWin, targetBuf);
    }
    await sync();
  }

  /// Closes all tabs to the right of [bufId] (or the active buffer) in editor split [winId].
  /// Other splits keep their own tabs untouched.
  Future<void> closeTabsToRight({
    int? winId,
    int? bufId,
    int? fallbackEditorWin,
  }) async {
    final targetWin = await _resolveTargetEditorWin(winId, fallbackEditorWin);
    if (targetWin == null) return;

    await sync();
    final tabs = _winTabs[targetWin];
    if (tabs == null || tabs.isEmpty) return;

    final currentBuf = await nvim.winGetBuf(targetWin);
    final targetBuf = (bufId != null && bufId > 0 && tabs.contains(bufId))
        ? bufId
        : (_winActiveBuf[targetWin] ?? currentBuf);
    final idx = tabs.indexOf(targetBuf);
    if (idx < 0 || idx >= tabs.length - 1) return;

    tabs.removeRange(idx + 1, tabs.length);
    if (!tabs.contains(currentBuf)) {
      _winActiveBuf[targetWin] = targetBuf;
      await nvim.winSetBuf(targetWin, targetBuf);
    } else if (!tabs.contains(_winActiveBuf[targetWin])) {
      _winActiveBuf[targetWin] = currentBuf;
    }
    await sync();
  }

  /// Closes all tabs in editor split [winId] (or current editor split).
  /// If other editor splits exist, closes this split; otherwise preserves the
  /// last editor pane with [onShowEmptyHome] (or an unnamed buffer fallback).
  Future<void> closeAllTabs({
    int? winId,
    int? fallbackEditorWin,
  }) async {
    final targetWin = await _resolveTargetEditorWin(winId, fallbackEditorWin);
    if (targetWin == null) return;

    await sync();
    final tabs = _winTabs[targetWin];
    if (tabs != null) {
      if (onTabClosedPath != null) {
        for (final b in tabs) {
          try {
            final name = (await nvim.bufGetName(b)).trim();
            if (name.isNotEmpty) {
              onTabClosedPath!(name);
            }
          } catch (_) {}
        }
      }
      tabs.clear();
    }
    await _handleEmptyEditorPane(targetWin);
    await sync();
  }

  Future<void> _handleEmptyEditorPane(int targetWin) async {
    _winActiveBuf.remove(targetWin);
    final allWins = await nvim.listWins();
    final otherEditorWins = <int>[];
    for (final w in allWins) {
      if (w != targetWin && await _isEditorWin(w)) {
        otherEditorWins.add(w);
      }
    }
    if (otherEditorWins.isNotEmpty) {
      _winTabs.remove(targetWin);
      _lastWinbar.remove(targetWin);
      _winTabSpans.remove(targetWin);
      await nvim.winClose(targetWin, force: true);
      await nvim.setCurrentWin(otherEditorWins.first);
      return;
    }

    if (onShowEmptyHome != null) {
      await onShowEmptyHome!(targetWin);
      return;
    }

    final emptyBuf = await nvim.createBuf(listed: true, scratch: false);
    await nvim.winSetBuf(targetWin, emptyBuf);
  }

  /// Copies the normalized path of [bufId] (or the active buffer) in editor split [winId].
  Future<void> copyTabPath({
    int? winId,
    int? bufId,
    int? fallbackEditorWin,
  }) async {
    final normPath = await _resolveTabFilePath(
      winId: winId,
      bufId: bufId,
      fallbackEditorWin: fallbackEditorWin,
    );
    if (normPath == null) return;
    await nvim.copyToClipboard(normPath);
    await nvim.notify('Copied path: $normPath');
  }

  /// Reveals [bufId] (or the active buffer) in Finder / OS file manager.
  Future<void> revealTabInFinder({
    int? winId,
    int? bufId,
    int? fallbackEditorWin,
  }) async {
    final normPath = await _resolveTabFilePath(
      winId: winId,
      bufId: bufId,
      fallbackEditorWin: fallbackEditorWin,
    );
    if (normPath == null || onRevealInFinder == null) return;
    try {
      await onRevealInFinder!(normPath);
    } catch (e) {
      await nvim.notify('Reveal in Finder failed: $e', level: 4);
    }
  }

  Future<String?> _resolveTabFilePath({
    int? winId,
    int? bufId,
    int? fallbackEditorWin,
  }) async {
    final targetWin = await _resolveTargetEditorWin(winId, fallbackEditorWin);
    if (targetWin == null) return null;

    await sync();
    final tabs = _winTabs[targetWin] ?? const <int>[];
    final currentBuf = await nvim.winGetBuf(targetWin);
    final targetBuf = (bufId != null && bufId > 0 && await nvim.bufIsValid(bufId))
        ? bufId
        : (_winActiveBuf[targetWin] ??
            (tabs.isNotEmpty ? tabs.first : currentBuf));
    if (targetBuf <= 0 || !await nvim.bufIsValid(targetBuf)) return null;
    final rawPath = (await nvim.bufGetName(targetBuf)).trim();
    if (rawPath.isEmpty) return null;
    return _normalizePath(rawPath);
  }

  /// Cycles through the tabs of [winId] (or the active editor split) by [delta].
  Future<void> cycleTab(
    int delta, {
    int? winId,
    int? fallbackEditorWin,
  }) async {
    final targetWin = await _resolveTargetEditorWin(winId, fallbackEditorWin);
    if (targetWin == null) return;

    await sync();
    final tabs = _winTabs[targetWin];
    if (tabs == null || tabs.length <= 1) return;

    final currentBuf = _winActiveBuf[targetWin] ?? await nvim.winGetBuf(targetWin);
    final curIdx = tabs.indexOf(currentBuf);
    final baseIdx = curIdx >= 0 ? curIdx : 0;
    final nextIdx = (baseIdx + delta) % tabs.length;
    final resolvedIdx = nextIdx < 0 ? nextIdx + tabs.length : nextIdx;
    final nextBuf = tabs[resolvedIdx];

    _winActiveBuf[targetWin] = nextBuf;
    await nvim.setCurrentWin(targetWin);
    await nvim.winSetBuf(targetWin, nextBuf);
    await sync();
  }

  Future<int?> _resolveTargetEditorWin(
    int? explicitWin,
    int? fallbackEditorWin,
  ) async {
    if (explicitWin != null && explicitWin > 0 && await _isEditorWin(explicitWin)) {
      return explicitWin;
    }
    final curWin = await nvim.getCurrentWin();
    if (await _isEditorWin(curWin)) {
      return curWin;
    }
    if (fallbackEditorWin != null &&
        fallbackEditorWin > 0 &&
        await _isEditorWin(fallbackEditorWin)) {
      return fallbackEditorWin;
    }
    final wins = await nvim.listWins();
    for (final w in wins) {
      if (await _isEditorWin(w)) return w;
    }
    return null;
  }

  (String, List<_TabColumnSpan>) _buildWinbarString({
    required List<int> tabs,
    required int activeBuf,
    required Map<int, String> bufPaths,
    required Map<int, bool> bufModified,
    required int maxWidth,
  }) {
    final labels = _disambiguateLabels(tabs, bufPaths);
    final renderedItems = <_RenderedTabItem>[];

    for (final buf in tabs) {
      final path = bufPaths[buf] ?? '';
      final label = labels[buf] ?? _basename(path);
      final icon = _iconForPath(path);
      final mod = (bufModified[buf] ?? false) ? ' ●' : '';
      final escapedLabel = label.replaceAll('%', '%%');
      final isActive = buf == activeBuf;
      final hl = isActive ? '%#VibrainiumTabActive#' : '%#VibrainiumTabInactive#';

      // Display text inside the tab: ` <icon> <label><mod> ✕ `
      final displayWidth = 1 + icon.runes.length + 1 + label.runes.length + mod.runes.length + 3;
      final code = '$hl%$buf@v:lua.VibrainiumWinbarSelect@ $icon $escapedLabel$mod %X'
          '%$buf@v:lua.VibrainiumWinbarClose@✕ %X';
      renderedItems.add(
        _RenderedTabItem(
          buf: buf,
          displayWidth: displayWidth,
          code: code,
        ),
      );
    }

    // Slice visible range around active tab if total width exceeds maxWidth.
    final activeIdx = tabs.indexOf(activeBuf).clamp(0, renderedItems.length - 1);
    var startIdx = activeIdx;
    var endIdx = activeIdx;
    var usedWidth = renderedItems[activeIdx].displayWidth;
    final budget = (maxWidth - 4).clamp(12, 10000);

    while (startIdx > 0 || endIdx < renderedItems.length - 1) {
      var expanded = false;
      if (startIdx > 0) {
        final w = renderedItems[startIdx - 1].displayWidth + 1;
        if (usedWidth + w <= budget) {
          startIdx--;
          usedWidth += w;
          expanded = true;
        }
      }
      if (endIdx < renderedItems.length - 1) {
        final w = renderedItems[endIdx + 1].displayWidth + 1;
        if (usedWidth + w <= budget) {
          endIdx++;
          usedWidth += w;
          expanded = true;
        }
      }
      if (!expanded) break;
    }

    final buffer = StringBuffer();
    final spans = <_TabColumnSpan>[];
    var currentCol = 1;
    if (startIdx > 0) {
      buffer.write('%#VibrainiumTabInactive# ‹ %#VibrainiumTabSeparator#│');
      currentCol += 4;
    }
    for (var i = startIdx; i <= endIdx; i++) {
      final item = renderedItems[i];
      final startCol = currentCol;
      final endCol = currentCol + item.displayWidth - 1;
      spans.add(_TabColumnSpan(buf: item.buf, startCol: startCol, endCol: endCol));
      buffer.write(item.code);
      buffer.write('%#VibrainiumTabSeparator#│');
      currentCol = endCol + 2;
    }
    if (endIdx < renderedItems.length - 1) {
      buffer.write('%#VibrainiumTabInactive# › ');
    }
    buffer.write('%#VibrainiumTabInactive#%=');
    return (buffer.toString(), spans);
  }

  Map<int, String> _disambiguateLabels(
    List<int> tabs,
    Map<int, String> bufPaths,
  ) {
    final byBasename = <String, List<int>>{};
    for (final buf in tabs) {
      final base = _basename(bufPaths[buf] ?? '');
      byBasename.putIfAbsent(base, () => <int>[]).add(buf);
    }

    final result = <int, String>{};
    for (final entry in byBasename.entries) {
      final base = entry.key;
      final group = entry.value;
      if (group.length == 1) {
        result[group.first] = base;
      } else {
        for (final buf in group) {
          final parent = _parentName(bufPaths[buf] ?? '');
          result[buf] = parent.isNotEmpty ? '$parent/$base' : base;
        }
      }
    }
    return result;
  }

  static bool _isPreviewablePath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.md') ||
        lower.endsWith('.markdown') ||
        lower.endsWith('.mdx') ||
        lower.endsWith('.svg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.heic');
  }

  static String _normalizePath(String rawPath) {
    var p = rawPath.replaceAll(r'\', '/').trim();
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static String _basename(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final idx = normalized.lastIndexOf('/');
    if (idx < 0) return normalized.isEmpty ? '[No Name]' : normalized;
    final sub = normalized.substring(idx + 1);
    return sub.isEmpty ? '[No Name]' : sub;
  }

  static String _parentName(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final idx = normalized.lastIndexOf('/');
    if (idx <= 0) return '';
    final parentPath = normalized.substring(0, idx);
    final parentIdx = parentPath.lastIndexOf('/');
    return parentIdx < 0 ? parentPath : parentPath.substring(parentIdx + 1);
  }

  static String _iconForPath(String path) {
    final lower = _basename(path).toLowerCase();
    final dot = lower.lastIndexOf('.');
    final ext = dot >= 0 ? lower.substring(dot + 1) : '';
    switch (ext) {
      case 'dart':
        return '';
      case 'lua':
        return '';
      case 'md':
      case 'markdown':
        return '';
      case 'yaml':
      case 'yml':
      case 'json':
      case 'toml':
        return '';
      case 'ts':
      case 'tsx':
        return '';
      case 'js':
      case 'jsx':
        return '';
      case 'py':
        return '';
      case 'rs':
        return '';
      case 'go':
        return '';
      case 'sh':
      case 'zsh':
      case 'bash':
        return '';
      default:
        return '󰈙';
    }
  }
}

class _RenderedTabItem {
  final int buf;
  final int displayWidth;
  final String code;

  const _RenderedTabItem({
    required this.buf,
    required this.displayWidth,
    required this.code,
  });
}

class _TabColumnSpan {
  final int buf;
  final int startCol;
  final int endCol;

  const _TabColumnSpan({
    required this.buf,
    required this.startCol,
    required this.endCol,
  });
}
