import 'dart:io';

import 'package:nvim/nvim.dart';

/// Represents an interactive line entry inside [EditorHomeView].
class EditorHomeEntry {
  final int line1Based;
  final String? filePath;
  final String? action;

  const EditorHomeEntry({
    required this.line1Based,
    this.filePath,
    this.action,
  });
}

/// Represents an unchecked-in (modified/staged/untracked) file entry.
class EditorHomeVcsFile {
  final String path;
  final String statusCode;

  const EditorHomeVcsFile({
    required this.path,
    required this.statusCode,
  });
}

/// Manages the dummy home/dashboard buffer shown in the last remaining editor
/// pane when all editor tabs are closed.
///
/// The buffer is marked `buftype=nofile`, `buflisted=false`, and
/// `bufhidden=wipe` so Neovim automatically deletes it as soon as a real file
/// replaces it in the window.
class EditorHomeView {
  static const String homeFiletype = 'vibrainium-home';

  final Nvim nvim;
  final Future<String?> Function()? getWorkspaceRoot;
  final Future<List<EditorHomeVcsFile>> Function(String workspaceRoot)?
      getUncheckedInFiles;
  final bool Function(String path)? fileExists;
  final DateTime? Function(String path)? fileModifiedAt;

  int? _bufId;
  int? _nsId;
  int? _lastWinId;
  final List<String> _recentSessionFiles = [];
  List<EditorHomeEntry> _entries = const [];

  EditorHomeView({
    required this.nvim,
    this.getWorkspaceRoot,
    this.getUncheckedInFiles,
    this.fileExists,
    this.fileModifiedAt,
  });

  int? get bufId => _bufId;
  List<EditorHomeEntry> get entries => List.unmodifiable(_entries);

  /// Records a file path (e.g. when a tab is closed) so it appears at the top
  /// of the Recently Opened Files list.
  void recordRecentFile(String path) {
    final normalized = _normalizePath(path);
    if (normalized.isEmpty) return;
    _recentSessionFiles.remove(normalized);
    _recentSessionFiles.insert(0, normalized);
    if (_recentSessionFiles.length > 20) {
      _recentSessionFiles.removeRange(20, _recentSessionFiles.length);
    }
  }

  /// Opens (or refreshes) the home buffer inside [winId] and focuses it.
  Future<int> showInWindow(int winId) async {
    _lastWinId = winId;
    var buf = _bufId;
    if (buf == null || !await nvim.bufIsValid(buf)) {
      buf = await nvim.createBuf(listed: false, scratch: true);
      _bufId = buf;
      await _configureBuffer(buf);
      await _bindKeymaps(buf);
    }

    await nvim.winSetBuf(winId, buf);
    await _render(buf, winId);
    return buf;
  }

  /// Deletes the dummy home buffer if it is no longer displayed in any window.
  Future<void> cleanupIfHidden() async {
    final buf = _bufId;
    if (buf == null) return;
    try {
      if (!await nvim.bufIsValid(buf)) {
        _bufId = null;
        return;
      }
      final wins = await nvim.listWins();
      for (final w in wins) {
        if (await nvim.winIsValid(w) && await nvim.winGetBuf(w) == buf) {
          return;
        }
      }
      await nvim.execLua(
        'pcall(vim.api.nvim_buf_delete, ..., { force = true })',
        [buf],
      );
    } catch (_) {}
    _bufId = null;
  }

  /// Handles `home.*` actions triggered by keymaps or mouse clicks in the
  /// home buffer. Returns the activated [EditorHomeEntry] if any.
  Future<void> handleAction(
    String action, {
    required Future<void> Function(String filePath, int? targetWin) onOpenFile,
    required Future<void> Function(String searchAction) onTriggerSearch,
  }) async {
    switch (action) {
      case 'home.activate':
        final win = await _resolveHomeWin();
        if (win == null) return;
        final (row, _) = await nvim.winGetCursor(win);
        final entry = _entryForLine(row);
        if (entry == null) return;
        if (entry.filePath != null) {
          await onOpenFile(entry.filePath!, win);
        } else if (entry.action != null) {
          await onTriggerSearch(entry.action!);
        }
        return;
      case 'home.next_item':
        await _jumpRelative(1);
        return;
      case 'home.prev_item':
        await _jumpRelative(-1);
        return;
      case 'home.action_files':
        await onTriggerSearch('search.files');
        return;
      case 'home.action_grep':
        await onTriggerSearch('search.text');
        return;
      case 'home.action_symbols':
        await onTriggerSearch('search.symbols');
        return;
      case 'home.refresh':
        final win = await _resolveHomeWin();
        final buf = _bufId;
        if (win != null && buf != null && await nvim.bufIsValid(buf)) {
          await _render(buf, win);
        }
        return;
    }
  }

  Future<void> _configureBuffer(int buf) async {
    await nvim.bufSetOption(buf, 'buftype', 'nofile');
    await nvim.bufSetOption(buf, 'bufhidden', 'wipe');
    await nvim.bufSetOption(buf, 'swapfile', false);
    await nvim.bufSetOption(buf, 'buflisted', false);
    await nvim.bufSetOption(buf, 'filetype', homeFiletype);
    await nvim.bufSetOption(buf, 'modifiable', false);
    await nvim.bufSetOption(buf, 'readonly', true);
  }

  Future<void> _bindKeymaps(int buf) async {
    const keymaps = <String, String>{
      '<CR>': 'home.activate',
      'o': 'home.activate',
      '<2-LeftMouse>': 'home.activate',
      '<Tab>': 'home.next_item',
      '<S-Tab>': 'home.prev_item',
      'f': 'home.action_files',
      'g': 'home.action_grep',
      's': 'home.action_symbols',
      'r': 'home.refresh',
    };
    for (final entry in keymaps.entries) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        entry.key,
        "<cmd>lua require('vibrainium').action('${entry.value}')<CR>",
        silent: true,
        nowait: true,
      );
    }
  }

  Future<void> _render(int buf, int winId) async {
    _nsId ??= await nvim.createNamespace('vibrainium_home');
    final workspaceRoot = await getWorkspaceRoot?.call();
    final recentFiles = await _collectRecentFiles(workspaceRoot);
    final uncheckedInFiles = await _collectUncheckedInFiles(workspaceRoot);
    final hasLsp = await _hasAttachedLsp();

    final lines = <String>[];
    final entries = <EditorHomeEntry>[];
    final hlRanges = <(int line0, String group, int startCol, int endCol)>[];

    void addLine(String text, {String? hlGroup}) {
      final lineIdx = lines.length;
      lines.add(text);
      if (hlGroup != null && text.isNotEmpty) {
        hlRanges.add((lineIdx, hlGroup, 0, text.length));
      }
    }

    void addFileSection({
      required String title,
      required List<({String path, String? badge, bool openable})> items,
      required String emptyText,
    }) {
      addLine('');
      addLine('  $title', hlGroup: 'Statement');
      if (items.isEmpty) {
        addLine('    $emptyText', hlGroup: 'Comment');
        return;
      }
      for (final item in items) {
        final display = _formatDisplayPath(item.path, workspaceRoot);
        final prefix = item.badge != null ? '[${item.badge}] ' : '󰈙  ';
        addLine('    $prefix$display');
        if (item.openable) {
          entries.add(EditorHomeEntry(
            line1Based: lines.length,
            filePath: item.path,
          ));
        }
      }
    }

    addLine('');
    addLine('  Vibrainium', hlGroup: 'Title');
    if (workspaceRoot != null && workspaceRoot.isNotEmpty) {
      addLine('  $workspaceRoot', hlGroup: 'Comment');
    }
    addLine('');

    addLine('  Quick Actions', hlGroup: 'Statement');
    final actions = <(String label, String shortcut, String action)>[
      ('󰈞  Find File', '[f]', 'search.files'),
      ('󰊄  Search Text', '[g]', 'search.text'),
      (
        hasLsp
            ? '󰌗  Workspace Symbols'
            : '󰌗  Workspace Symbols (open a file to start LSP)',
        '[s]',
        'search.symbols',
      ),
    ];
    for (final item in actions) {
      final lineText = '    ${item.$1}  ${item.$2}';
      addLine(lineText);
      entries.add(EditorHomeEntry(
        line1Based: lines.length,
        action: item.$3,
      ));
    }

    addFileSection(
      title: 'Unchecked-in Files',
      emptyText: '(clean working tree)',
      items: [
        for (final f in uncheckedInFiles)
          (
            path: f.path,
            badge: f.statusCode,
            openable: f.statusCode != 'D',
          ),
      ],
    );

    addFileSection(
      title: 'Recently Opened Files',
      emptyText: '(no recent files)',
      items: [
        for (final p in recentFiles)
          (path: p, badge: null, openable: true),
      ],
    );

    addLine('');
    addLine(
      '  <CR>/o open  •  <Tab>/<S-Tab> jump  •  r refresh',
      hlGroup: 'Comment',
    );

    _entries = entries;

    await nvim.bufSetOption(buf, 'readonly', false);
    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetLines(buf, lines: lines);
    await nvim.bufClearNamespace(buf, _nsId!);
    for (final hl in hlRanges) {
      await nvim.bufSetExtmark(
        buf,
        _nsId!,
        hl.$1,
        hl.$3,
        {'end_col': hl.$4, 'hl_group': hl.$2},
      );
    }
    await nvim.bufSetOption(buf, 'modifiable', false);
    await nvim.bufSetOption(buf, 'readonly', true);

    if (entries.isNotEmpty) {
      await nvim.winSetCursor(winId, entries.first.line1Based, 4);
    }
  }

  Future<List<String>> _collectRecentFiles(String? workspaceRoot) async {
    final seen = <String>{};
    final result = <String>[];
    final existsCheck = fileExists ?? (String p) => File(p).existsSync();

    void tryAdd(String raw) {
      final normalized = _normalizePath(raw);
      if (normalized.isEmpty || seen.contains(normalized)) return;
      if (normalized.contains('://')) return;
      if (!existsCheck(normalized)) return;
      seen.add(normalized);
      result.add(normalized);
    }

    for (final p in _recentSessionFiles) {
      tryAdd(p);
      if (result.length >= 12) return result;
    }

    try {
      final rawOld = await nvim.execLua('return vim.v.oldfiles or {}');
      if (rawOld is List) {
        for (final item in rawOld) {
          if (item is String) {
            tryAdd(item);
            if (result.length >= 12) break;
          }
        }
      }
    } catch (_) {}

    if (workspaceRoot != null && workspaceRoot.isNotEmpty) {
      final normRoot = _normalizePath(workspaceRoot);
      result.sort((a, b) {
        final aIn = a.startsWith('$normRoot/') ? 0 : 1;
        final bIn = b.startsWith('$normRoot/') ? 0 : 1;
        return aIn.compareTo(bIn);
      });
    }

    return result;
  }

  Future<List<EditorHomeVcsFile>> _collectUncheckedInFiles(
    String? workspaceRoot,
  ) async {
    if (workspaceRoot == null || workspaceRoot.isEmpty) return const [];
    final provider = getUncheckedInFiles;
    List<EditorHomeVcsFile> items;
    if (provider != null) {
      try {
        items = List<EditorHomeVcsFile>.from(await provider(workspaceRoot));
      } catch (_) {
        return const [];
      }
    } else {
      items = await _defaultGitStatus(workspaceRoot);
    }

    final mtimeFn = fileModifiedAt ?? _defaultFileModifiedAt;
    final mtimes = <String, DateTime?>{
      for (final f in items)
        f.path: f.statusCode == 'D' ? null : mtimeFn(f.path),
    };
    items.sort((a, b) {
      final ta = mtimes[a.path];
      final tb = mtimes[b.path];
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });
    return items.take(12).toList();
  }

  DateTime? _defaultFileModifiedAt(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      return f.statSync().modified;
    } catch (_) {
      return null;
    }
  }

  Future<List<EditorHomeVcsFile>> _defaultGitStatus(String root) async {
    if (!Directory(root).existsSync()) return const [];
    try {
      final res = await Process.run(
        'git',
        ['status', '--porcelain'],
        workingDirectory: root,
      );
      if (res.exitCode != 0) return const [];
      final normRoot = _normalizePath(root);
      final seen = <String>{};
      final out = <EditorHomeVcsFile>[];
      for (final rawLine in res.stdout.toString().split('\n')) {
        if (rawLine.length < 4) continue;
        final xy = rawLine.substring(0, 2);
        var rel = rawLine.substring(3).trim();
        final arrow = rel.indexOf(' -> ');
        if (arrow >= 0) rel = rel.substring(arrow + 4).trim();
        if (rel.isEmpty) continue;
        final abs = _normalizePath('$normRoot/$rel');
        if (!seen.add(abs)) continue;
        final code = xy.contains('?')
            ? '?'
            : (xy.trim().isEmpty ? 'M' : xy.trim()[0]);
        out.add(EditorHomeVcsFile(path: abs, statusCode: code));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<bool> _hasAttachedLsp() async {
    try {
      final res = await nvim.execLua(
        'return #(vim.lsp.get_clients and vim.lsp.get_clients() or vim.lsp.get_active_clients()) > 0',
      );
      return res == true;
    } catch (_) {
      return false;
    }
  }

  Future<int?> _resolveHomeWin() async {
    final buf = _bufId;
    if (buf == null) return null;
    try {
      final curWin = await nvim.getCurrentWin();
      if (await nvim.winIsValid(curWin) && await nvim.winGetBuf(curWin) == buf) {
        return curWin;
      }
      if (_lastWinId != null &&
          await nvim.winIsValid(_lastWinId!) &&
          await nvim.winGetBuf(_lastWinId!) == buf) {
        return _lastWinId;
      }
      for (final w in await nvim.listWins()) {
        if (await nvim.winIsValid(w) && await nvim.winGetBuf(w) == buf) {
          return w;
        }
      }
    } catch (_) {}
    return null;
  }

  EditorHomeEntry? _entryForLine(int line1Based) {
    for (final e in _entries) {
      if (e.line1Based == line1Based) return e;
    }
    return null;
  }

  Future<void> _jumpRelative(int delta) async {
    if (_entries.isEmpty) return;
    final win = await _resolveHomeWin();
    if (win == null) return;
    final (row, _) = await nvim.winGetCursor(win);
    final curIdx = _entries.indexWhere((e) => e.line1Based == row);
    int nextIdx;
    if (curIdx < 0) {
      nextIdx = delta > 0 ? 0 : _entries.length - 1;
    } else {
      nextIdx = (curIdx + delta) % _entries.length;
      if (nextIdx < 0) nextIdx += _entries.length;
    }
    await nvim.winSetCursor(win, _entries[nextIdx].line1Based, 4);
  }

  static String _normalizePath(String raw) {
    return raw.trim().replaceAll(r'\', '/');
  }

  static String _formatDisplayPath(String path, String? workspaceRoot) {
    if (workspaceRoot == null || workspaceRoot.isEmpty) return path;
    final normRoot = _normalizePath(workspaceRoot);
    final prefix = normRoot.endsWith('/') ? normRoot : '$normRoot/';
    if (path.startsWith(prefix)) {
      return path.substring(prefix.length);
    }
    return path;
  }
}
