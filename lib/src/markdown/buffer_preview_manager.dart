import 'dart:async';
import 'dart:io';
import 'package:nvim/nvim.dart';

import 'kitty_graphics.dart';
import 'markdown_rasterizer.dart';
import 'markdown_theme.dart';

/// Preview format supported by [BufferPreviewManager].
enum PreviewType {
  markdown,
  svg,
  image,
  unsupported,
}

class _PreviewSession {
  final int sourceBufId;
  final int previewBufId;
  final int winId;
  final bool isSplitMode;
  final int? originalBufId;
  final (int, int)? originalCursor;
  final int imageId;
  final PreviewType type;
  final String fileName;
  int lastWidth;
  int lastHeight;
  int lastScreenRow;
  int lastScreenCol;
  int lastTopLine;
  int? lastSourceTopLine;
  String lastContentHash;
  String? cachedSvg;
  List<int> cachedPngBytes = const [];
  int imageWidthPx = 0;
  int imageHeightPx = 0;
  int totalVirtualRows;

  _PreviewSession({
    required this.sourceBufId,
    required this.previewBufId,
    required this.winId,
    required this.isSplitMode,
    this.originalBufId,
    this.originalCursor,
    required this.imageId,
    required this.type,
    required this.fileName,
    required this.lastWidth,
    required this.lastHeight,
    required this.lastScreenRow,
    required this.lastScreenCol,
    this.lastTopLine = 1,
    this.lastSourceTopLine,
    required this.lastContentHash,
    this.totalVirtualRows = 0,
  });
}

/// Unified buffer preview manager supporting Markdown, SVG, and raster images (PNG, JPG, WEBP)
/// in Ghostty/Kitty using the Kitty Graphics Protocol.
class BufferPreviewManager {
  final Nvim nvim;
  final KittyGraphics kittyGraphics;
  final MarkdownRasterizer markdownRasterizer;
  final Future<List<int>> Function(String filePath)? _customImageLoader;

  final Map<int, _PreviewSession> _sessionsByWin = {};
  final Map<(int, int), int> _suspendedInPlace = {};
  int _nextImageId = 1000;

  BufferPreviewManager({
    required this.nvim,
    KittyGraphics? kittyGraphics,
    MarkdownRasterizer? markdownRasterizer,
    Future<List<int>> Function(String filePath)? customImageLoader,
  })  : kittyGraphics = kittyGraphics ?? KittyGraphics(nvim: nvim),
        markdownRasterizer = markdownRasterizer ?? const MarkdownRasterizer(),
        _customImageLoader = customImageLoader;

  bool isPreviewWin(int winId) => _sessionsByWin.containsKey(winId);
  bool isSplitPreviewWin(int winId) =>
      _sessionsByWin[winId]?.isSplitMode == true;
  int? sourceBufForWin(int winId) => _sessionsByWin[winId]?.sourceBufId;

  /// Resolves the preview kind for a given buffer.
  Future<PreviewType> resolvePreviewType(int buf) async {
    try {
      final ft = (await nvim.bufGetOption(buf, 'filetype'))?.toString().toLowerCase() ?? '';
      if (ft == 'markdown' || ft == 'markdown.mdx' || ft == 'md') {
        return PreviewType.markdown;
      }
      final name = (await nvim.bufGetName(buf)).toLowerCase();
      if (name.endsWith('.md') || name.endsWith('.markdown') || name.endsWith('.mdx')) {
        return PreviewType.markdown;
      }
      if (name.endsWith('.svg')) {
        return PreviewType.svg;
      }
      if (name.endsWith('.png') ||
          name.endsWith('.jpg') ||
          name.endsWith('.jpeg') ||
          name.endsWith('.webp') ||
          name.endsWith('.gif') ||
          name.endsWith('.heic')) {
        return PreviewType.image;
      }
    } catch (_) {}
    return PreviewType.unsupported;
  }

  /// Toggles the current window between raw Editor Mode and Render Mode.
  Future<void> toggleInPlace({int? targetWin, int? restoreTopLine}) async {
    final win = targetWin ?? await nvim.getCurrentWin();
    if (win <= 0) return;

    final existing = _sessionsByWin[win];
    if (existing != null && !existing.isSplitMode) {
      // Revert to Editor Mode
      _suspendedInPlace.remove((existing.winId, existing.sourceBufId));
      await _closeSession(existing);
      return;
    }

    // Entering Render Mode
    final buf = await nvim.winGetBuf(win);
    _suspendedInPlace.remove((win, buf));
    final type = await resolvePreviewType(buf);
    if (type == PreviewType.unsupported) {
      final name = await nvim.bufGetName(buf);
      final ext = name.contains('.') ? name.split('.').last : 'this filetype';
      await nvim.notify('No preview available for $ext.', level: 3);
      return;
    }

    final pos = await nvim.winGetPosition(win);
    final width = await nvim.winGetWidth(win);
    final height = await nvim.winGetHeight(win);

    final rawName = await nvim.bufGetName(buf);
    final fileName = rawName.split('/').last;

    (int, int)? cursor;
    try {
      cursor = await nvim.winGetCursor(win);
    } catch (_) {}

    final scratchBuf = await nvim.createBuf(listed: false, scratch: true);
    await nvim.bufSetOption(scratchBuf, 'buftype', 'nofile');
    await nvim.bufSetOption(scratchBuf, 'filetype', 'vibrainium-preview');
    await nvim.bufSetOption(scratchBuf, 'bufhidden', 'wipe');
    await nvim.bufSetName(scratchBuf, 'Preview [Render Mode]: $fileName');

    final lines = await _getSourceLines(buf, type);
    final lineCount = (lines.length > height ? lines.length : height) + 10;
    await nvim.bufSetLines(
      scratchBuf,
      lines: List.filled(lineCount, ''),
    );

    await nvim.winSetBuf(win, scratchBuf);
    await _configurePreviewWindow(win);

    final textRow = pos.$1 + await _getWinbarOffset(win);
    final imageId = ++_nextImageId;
    final session = _PreviewSession(
      sourceBufId: buf,
      previewBufId: scratchBuf,
      winId: win,
      isSplitMode: false,
      originalBufId: buf,
      originalCursor: cursor,
      imageId: imageId,
      type: type,
      fileName: fileName,
      lastWidth: width,
      lastHeight: height,
      lastScreenRow: textRow,
      lastScreenCol: pos.$2,
      lastTopLine: 1,
      lastContentHash: lines.join('\n'),
      totalVirtualRows: height,
    );
    _sessionsByWin[win] = session;

    await _bindPreviewKeymaps(scratchBuf, isSplitMode: false);
    await _renderAndDisplay(session, textRow, pos.$2, width, height, rawName);
    if (restoreTopLine != null && restoreTopLine > 1) {
      try {
        await nvim.execLua(
          '''
          local win, top = ...
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_call(win, function()
              vim.fn.winrestview({ topline = top, lnum = top })
            end)
          end
          ''',
          [win, restoreTopLine],
        );
        await _syncSession(session);
      } catch (_) {}
    }
  }

  /// Opens or toggles a companion split preview for the active file.
  ///
  /// Reuses an existing split window if open; otherwise creates a new vertical split.
  Future<void> openSplitPreview({int? targetWin}) async {
    final win = targetWin ?? await nvim.getCurrentWin();
    if (win <= 0) return;

    final buf = await nvim.winGetBuf(win);
    final type = await resolvePreviewType(buf);
    if (type == PreviewType.unsupported) {
      final name = await nvim.bufGetName(buf);
      final ext = name.contains('.') ? name.split('.').last : 'this filetype';
      await nvim.notify('No preview available for $ext.', level: 3);
      return;
    }

    // Check if a split preview is already open for this source buffer
    for (final session in _sessionsByWin.values) {
      if (session.isSplitMode && session.sourceBufId == buf) {
        // Close existing split preview
        await _closeSession(session);
        return;
      }
    }

    final rawName = await nvim.bufGetName(buf);
    final fileName = rawName.split('/').last;

    int? previewWin;
    int? originalBufInSplit;
    try {
      final allWins = await nvim.listWins();
      for (final w in allWins) {
        if (w != win && await nvim.winIsValid(w)) {
          final cfg = await nvim.winGetConfig(w);
          final rel = cfg['relative']?.toString() ?? '';
          if (rel.isEmpty) {
            final wBuf = await nvim.winGetBuf(w);
            final ft = (await nvim.bufGetOption(wBuf, 'filetype'))?.toString() ?? '';
            if (!ft.startsWith('viworkspace') &&
                !ft.startsWith('vivcs') &&
                !ft.startsWith('viagent') &&
                !ft.startsWith('viproblems') &&
                !ft.startsWith('vibrainium-tabbar') &&
                !ft.startsWith('vibrainium-bottom-tabbar')) {
              previewWin = w;
              originalBufInSplit = wBuf;
              break;
            }
          }
        }
      }
    } catch (_) {}

    if (previewWin == null) {
      // Create vertical split
      await nvim.command('rightbelow vsplit');
      previewWin = await nvim.getCurrentWin();
    }

    final scratchBuf = await nvim.createBuf(listed: false, scratch: true);
    await nvim.bufSetOption(scratchBuf, 'buftype', 'nofile');
    await nvim.bufSetOption(scratchBuf, 'filetype', 'vibrainium-preview');
    await nvim.bufSetOption(scratchBuf, 'bufhidden', 'wipe');
    await nvim.bufSetName(scratchBuf, 'Preview: $fileName');

    final lines = await _getSourceLines(buf, type);
    final height = await nvim.winGetHeight(previewWin);
    final width = await nvim.winGetWidth(previewWin);

    final lineCount = (lines.length > height ? lines.length : height) + 10;
    await nvim.bufSetLines(
      scratchBuf,
      lines: List.filled(lineCount, ''),
    );

    await nvim.winSetBuf(previewWin, scratchBuf);
    await _configurePreviewWindow(previewWin);

    final pos = await nvim.winGetPosition(previewWin);
    final textRow = pos.$1 + await _getWinbarOffset(previewWin);
    final imageId = ++_nextImageId;
    int? sourceTopLine;
    try {
      sourceTopLine = await nvim.winGetTopLine(win);
    } catch (_) {}

    final session = _PreviewSession(
      sourceBufId: buf,
      previewBufId: scratchBuf,
      winId: previewWin,
      isSplitMode: true,
      originalBufId: originalBufInSplit,
      imageId: imageId,
      type: type,
      fileName: fileName,
      lastWidth: width,
      lastHeight: height,
      lastScreenRow: textRow,
      lastScreenCol: pos.$2,
      lastTopLine: 1,
      lastSourceTopLine: sourceTopLine,
      lastContentHash: lines.join('\n'),
      totalVirtualRows: height,
    );
    _sessionsByWin[previewWin] = session;

    await _bindPreviewKeymaps(scratchBuf, isSplitMode: true);
    await _bindScrollAutocmd(buf);
    await _renderAndDisplay(session, textRow, pos.$2, width, height, rawName);
  }

  /// Refreshes any active preview whose source buffer is [bufId].
  Future<void> onSourceBufferChanged(int bufId) async {
    for (final session in _sessionsByWin.values) {
      if (session.sourceBufId == bufId) {
        if (!await nvim.winIsValid(session.winId)) continue;
        final rawName = await nvim.bufGetName(bufId);
        final lines = await _getSourceLines(bufId, session.type);
        final content = lines.join('\n');
        if (content == session.lastContentHash) continue;
        session.lastContentHash = content;

        final pos = await nvim.winGetPosition(session.winId);
        final textRow = pos.$1 + await _getWinbarOffset(session.winId);
        final width = await nvim.winGetWidth(session.winId);
        final height = await nvim.winGetHeight(session.winId);
        session.lastWidth = width;
        session.lastHeight = height;
        session.lastScreenRow = textRow;
        session.lastScreenCol = pos.$2;
        await _renderAndDisplay(session, textRow, pos.$2, width, height, rawName);
      }
    }
  }

  Timer? _syncDebounce;

  /// Syncs all active preview sessions with current window sizes and positions.
  Future<void> syncAll({bool immediate = false}) async {
    if (immediate) {
      _syncDebounce?.cancel();
      await _executeSyncAll();
      return;
    }
    _syncDebounce?.cancel();
    final completer = Completer<void>();
    _syncDebounce = Timer(const Duration(milliseconds: 30), () async {
      await _executeSyncAll();
      if (!completer.isCompleted) completer.complete();
    });
  }

  Future<void> _executeSyncAll() async {
    try {
      final sessions = _sessionsByWin.values.toList();
      for (final session in sessions) {
        await _syncSession(session);
      }
    } catch (_) {}
  }

  /// Syncs graphic position and dimensions on window resize or scroll.
  Future<void> syncWindow(int winId) async {
    final session = _sessionsByWin[winId];
    if (session == null) return;
    await _syncSession(session);
  }

  /// Removes any preview session whose window is no longer valid or has switched
  /// away from its preview scratch buffer (e.g. when switching tabs), and
  /// automatically restores any suspended in-place preview when its source
  /// buffer becomes active again in that window.
  Future<void> pruneStaleSessions() async {
    final sessions = _sessionsByWin.values.toList();
    for (final session in sessions) {
      try {
        if (!await nvim.winIsValid(session.winId)) {
          _suspendedInPlace.removeWhere((k, _) => k.$1 == session.winId);
          await _detachSession(session);
          continue;
        }
        final currentBuf = await nvim.winGetBuf(session.winId);
        if (currentBuf != session.previewBufId) {
          if (!session.isSplitMode && await nvim.bufIsValid(session.sourceBufId)) {
            _suspendedInPlace[(session.winId, session.sourceBufId)] =
                session.lastTopLine;
          }
          await _detachSession(session);
        }
      } catch (_) {}
    }

    for (final key in _suspendedInPlace.keys.toList()) {
      final (winId, sourceBufId) = key;
      if (_sessionsByWin.containsKey(winId)) continue;
      try {
        if (!await nvim.winIsValid(winId) ||
            !await nvim.bufIsValid(sourceBufId)) {
          _suspendedInPlace.remove(key);
          continue;
        }
        final currentBuf = await nvim.winGetBuf(winId);
        if (currentBuf == sourceBufId) {
          final savedTop = _suspendedInPlace.remove(key) ?? 1;
          await toggleInPlace(targetWin: winId, restoreTopLine: savedTop);
        }
      } catch (_) {}
    }
  }

  Future<void> _syncSession(_PreviewSession session) async {
    if (!await nvim.winIsValid(session.winId)) {
      await _detachSession(session);
      return;
    }

    final currentBuf = await nvim.winGetBuf(session.winId);
    if (currentBuf != session.previewBufId) {
      await _detachSession(session);
      return;
    }

    final width = await nvim.winGetWidth(session.winId);
    final height = await nvim.winGetHeight(session.winId);
    final pos = await nvim.winGetPosition(session.winId);
    final textRow = pos.$1 + await _getWinbarOffset(session.winId);
    var topLine = await _safeGetTopLine(session.winId);

    if (session.isSplitMode) {
      final syncedTop = await _syncSplitSourceScroll(session, height);
      if (syncedTop != null) {
        topLine = syncedTop;
      }
    }

    final widthChanged = width != session.lastWidth;
    final geometryChanged = widthChanged ||
        height != session.lastHeight ||
        textRow != session.lastScreenRow ||
        pos.$2 != session.lastScreenCol;
    final scrollChanged = topLine != session.lastTopLine;

    if (!geometryChanged && !scrollChanged) return;

    session.lastWidth = width;
    session.lastHeight = height;
    session.lastScreenRow = textRow;
    session.lastScreenCol = pos.$2;
    session.lastTopLine = topLine;

    final hasCachedContent =
        session.cachedSvg != null || session.cachedPngBytes.isNotEmpty;
    if (widthChanged || !hasCachedContent) {
      final rawName = await nvim.bufGetName(session.sourceBufId);
      await _renderAndDisplay(session, textRow, pos.$2, width, height, rawName);
    } else {
      await _displayCachedImage(
        session,
        textRow,
        pos.$2,
        width,
        height,
        topLine,
      );
    }
  }

  Future<int> _getWinbarOffset(int winId) async {
    try {
      final res = await nvim.rpc.request(
        'nvim_get_option_value',
        [
          'winbar',
          {'win': winId},
        ],
      );
      final wb = res?.toString() ?? '';
      return wb.isNotEmpty ? 1 : 0;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _safeGetTopLine(int winId) async {
    try {
      return await nvim.winGetTopLine(winId);
    } catch (_) {
      return 1;
    }
  }

  /// Proportionally scrolls a split preview window when its source editor window scrolls.
  Future<int?> _syncSplitSourceScroll(
    _PreviewSession session,
    int previewHeight,
  ) async {
    try {
      final allWins = await nvim.listWins();
      int? sourceWin;
      for (final w in allWins) {
        if (w != session.winId && await nvim.winIsValid(w)) {
          if (await nvim.winGetBuf(w) == session.sourceBufId) {
            sourceWin = w;
            break;
          }
        }
      }
      if (sourceWin == null) return null;

      final sourceTopLine = await nvim.winGetTopLine(sourceWin);
      if (session.lastSourceTopLine == sourceTopLine) {
        return null;
      }
      session.lastSourceTopLine = sourceTopLine;

      final sourceLines = await nvim.bufGetLines(session.sourceBufId);
      final maxSourceTop = sourceLines.length > 1 ? sourceLines.length - 1 : 1;
      final ratio = ((sourceTopLine - 1) / maxSourceTop).clamp(0.0, 1.0);
      final maxPreviewTop =
          (session.totalVirtualRows - previewHeight + 1).clamp(1, 1000000);
      final targetTopLine = (ratio * (maxPreviewTop - 1)).round() + 1;

      await nvim.rpc.request('nvim_call_function', [
        'win_execute',
        [session.winId, 'keepjumps normal! ${targetTopLine}Gzt'],
      ]);
      return targetTopLine;
    } catch (_) {
      return null;
    }
  }

  Future<void> _bindPreviewKeymaps(
    int scratchBuf, {
    required bool isSplitMode,
  }) async {
    final keymaps = <String, String>{
      'q': isSplitMode
          ? '<cmd>close<cr>'
          : '<cmd>lua _G.VibrainiumBufferPreviewToggle()<cr>',
      'j': '<C-e>',
      'k': '<C-y>',
      '<Down>': '<C-e>',
      '<Up>': '<C-y>',
      '<Space>': '<C-f>',
      'gg': '<cmd>keepjumps normal! 1Gzt<cr>',
      'G': '<cmd>keepjumps normal! Gzt<cr>',
    };
    for (final entry in keymaps.entries) {
      try {
        await nvim.bufSetKeymap(
          scratchBuf,
          'n',
          entry.key,
          entry.value,
          nowait: true,
          silent: true,
        );
      } catch (_) {}
    }
    await _bindScrollAutocmd(scratchBuf);
  }

  Future<void> _bindScrollAutocmd(int bufId) async {
    try {
      await nvim.execLua(
        '''
        local buf = ...
        local grp = vim.api.nvim_create_augroup('VibrainiumPreviewScroll_' .. buf, { clear = true })
        vim.api.nvim_create_autocmd({ 'WinScrolled', 'CursorMoved' }, {
          group = grp,
          buffer = buf,
          callback = function()
            pcall(function()
              require('vibrainium').action('buffer.scroll')
            end)
          end,
        })
        ''',
        [bufId],
      );
    } catch (_) {}
  }

  Future<void> _configurePreviewWindow(int win) async {
    try {
      await nvim.winSetOption(win, 'number', false);
      await nvim.winSetOption(win, 'relativenumber', false);
      await nvim.winSetOption(win, 'signcolumn', 'no');
      await nvim.winSetOption(win, 'foldcolumn', '0');
      await nvim.winSetOption(win, 'cursorline', false);
      await nvim.winSetOption(win, 'wrap', false);
    } catch (_) {}
  }

  /// Returns formatted tab title for the preview window if active.
  String? getPreviewTitle(int winId) {
    final session = _sessionsByWin[winId];
    if (session == null) return null;
    return '󰍔 Preview: ${session.fileName}';
  }

  /// Closes preview session associated with [winId].
  Future<void> closePreview(int winId) async {
    final session = _sessionsByWin[winId];
    if (session != null) {
      await _closeSession(session);
    }
  }

  /// Closes all active preview sessions and cleans up Kitty graphics.
  Future<void> closeAllPreviews() async {
    _suspendedInPlace.clear();
    final sessions = _sessionsByWin.values.toList();
    for (final s in sessions) {
      await _closeSession(s);
    }
    await kittyGraphics.deleteAll();
  }

  Future<void> _closeSession(_PreviewSession session) async {
    await kittyGraphics.deleteImage(session.imageId);
    _sessionsByWin.remove(session.winId);

    if (!session.isSplitMode && session.originalBufId != null) {
      if (await nvim.winIsValid(session.winId) &&
          await nvim.bufIsValid(session.originalBufId!)) {
        await nvim.winSetBuf(session.winId, session.originalBufId!);
        if (session.originalCursor != null) {
          try {
            await nvim.winSetCursor(
              session.winId,
              session.originalCursor!.$1,
              session.originalCursor!.$2,
            );
          } catch (_) {}
        }
      }
    } else if (session.isSplitMode) {
      if (session.originalBufId != null) {
        if (await nvim.winIsValid(session.winId) &&
            await nvim.bufIsValid(session.originalBufId!)) {
          await nvim.winSetBuf(session.winId, session.originalBufId!);
        }
      } else if (await nvim.winIsValid(session.winId)) {
        await nvim.winClose(session.winId, force: true);
      }
    }

    if (await nvim.bufIsValid(session.previewBufId)) {
      await nvim.command('bdelete! ${session.previewBufId}');
    }
  }

  /// Detaches a preview session when its window was closed or switched to another
  /// buffer, cleaning up the Kitty graphic and scratch buffer without altering
  /// the window's new buffer.
  Future<void> _detachSession(_PreviewSession session) async {
    await kittyGraphics.deleteImage(session.imageId);
    _sessionsByWin.remove(session.winId);
    if (await nvim.bufIsValid(session.previewBufId)) {
      try {
        await nvim.command('bdelete! ${session.previewBufId}');
      } catch (_) {}
    }
  }

  static (int, int)? _getPngDimensions(List<int> bytes) {
    if (bytes.length >= 24 &&
        bytes[12] == 0x49 &&
        bytes[13] == 0x48 &&
        bytes[14] == 0x44 &&
        bytes[15] == 0x52) {
      final w = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
      final h = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
      return (w, h);
    }
    return null;
  }

  /// Resolves the active [MarkdownTheme] by querying Neovim's `background` option
  /// and highlight groups (`Normal`, `Comment`, `String`, `Title`, etc.).
  Future<MarkdownTheme> resolveMarkdownTheme() async {
    try {
      final bgOption = (await nvim.getOption('background'))?.toString() ?? 'dark';

      const hlGroups = [
        'Normal',
        'Comment',
        'String',
        'Title',
        '@markup.heading.1',
        '@markup.heading.2',
        '@markup.heading.3',
        'Special',
        'Constant',
        'Type',
        'Function',
        'Identifier',
        'ColorColumn',
        'CursorLine',
        'WinSeparator',
        'VertSplit',
        'Underlined',
        '@markup.link.url',
      ];

      final highlights = <String, Map<String, dynamic>>{};
      final results = await Future.wait(
        hlGroups.map((g) async {
          final hl = await nvim.getHl(g, link: false);
          return MapEntry(g, hl);
        }),
      );
      for (final entry in results) {
        if (entry.value != null && entry.value!.isNotEmpty) {
          highlights[entry.key] = entry.value!;
        }
      }

      return MarkdownTheme.fromNvimHighlights(
        background: bgOption,
        highlights: highlights,
      );
    } catch (_) {
      return MarkdownTheme.dark;
    }
  }

  Future<void> _renderAndDisplay(
    _PreviewSession session,
    int screenRow,
    int screenCol,
    int widthCols,
    int heightRows,
    String filePath,
  ) async {
    final widthPx = (widthCols * 10).clamp(600, 1920);
    final resolvedPath = await _resolveAbsolutePath(filePath);

    switch (session.type) {
      case PreviewType.markdown:
        final theme = await resolveMarkdownTheme();
        final svg = markdownRasterizer.markdownToSvg(
          session.lastContentHash,
          widthPx: widthPx,
          theme: theme,
        );
        session.cachedSvg = svg;
        session.cachedPngBytes = const [];
        final dims = MarkdownRasterizer.parseSvgDimensions(svg);
        session.imageWidthPx = dims?.$1 ?? widthPx;
        session.imageHeightPx = dims?.$2 ?? 0;
        break;

      case PreviewType.svg:
        session.cachedSvg = null;
        final pngBytes = await _rasterizeSvgFile(resolvedPath);
        session.cachedPngBytes = pngBytes;
        final dims = pngBytes.isNotEmpty ? _getPngDimensions(pngBytes) : null;
        session.imageWidthPx = dims?.$1 ?? 0;
        session.imageHeightPx = dims?.$2 ?? 0;
        break;

      case PreviewType.image:
        session.cachedSvg = null;
        final pngBytes = await _loadImageAsPng(resolvedPath);
        session.cachedPngBytes = pngBytes;
        final dims = pngBytes.isNotEmpty ? _getPngDimensions(pngBytes) : null;
        session.imageWidthPx = dims?.$1 ?? 0;
        session.imageHeightPx = dims?.$2 ?? 0;
        break;

      case PreviewType.unsupported:
        session.cachedSvg = null;
        session.cachedPngBytes = const [];
        break;
    }

    if (session.type == PreviewType.markdown &&
        session.imageWidthPx > 0 &&
        session.imageHeightPx > 0 &&
        widthCols > 0) {
      final pixelsPerRow = (2.0 * session.imageWidthPx) / widthCols;
      final virtualRows = (session.imageHeightPx / pixelsPerRow).ceil();
      final targetRows = virtualRows > heightRows ? virtualRows : heightRows;
      if (targetRows != session.totalVirtualRows) {
        session.totalVirtualRows = targetRows;
        try {
          if (await nvim.bufIsValid(session.previewBufId)) {
            await nvim.bufSetLines(
              session.previewBufId,
              lines: List.filled(targetRows + 10, ''),
            );
          }
        } catch (_) {}
      }
    }

    final topLine = await _safeGetTopLine(session.winId);
    session.lastTopLine = topLine;

    await _displayCachedImage(
      session,
      screenRow,
      screenCol,
      widthCols,
      heightRows,
      topLine,
    );
  }

  Future<void> _displayCachedImage(
    _PreviewSession session,
    int screenRow,
    int screenCol,
    int widthCols,
    int heightRows,
    int topLine,
  ) async {
    List<int> pngBytes = session.cachedPngBytes;
    int? displayCols;
    int? displayRows;

    final imgW = session.imageWidthPx;
    final imgH = session.imageHeightPx;

    if (session.type == PreviewType.markdown && session.cachedSvg != null) {
      if (imgW > 0 && imgH > 0 && widthCols > 0 && heightRows > 0) {
        final pixelsPerRow = (2.0 * imgW) / widthCols;
        final computedSrcY = ((topLine - 1) * pixelsPerRow).round();
        if (computedSrcY >= imgH) {
          // Scrolled past the bottom of the rendered image.
          await kittyGraphics.deleteImage(session.imageId);
          return;
        }
        final clampedSrcY = computedSrcY < 0 ? 0 : computedSrcY;
        final availableH = imgH - clampedSrcY;
        final desiredH = (heightRows * pixelsPerRow).round();
        final clippedH = desiredH < availableH ? desiredH : availableH;
        if (clippedH <= 0) {
          await kittyGraphics.deleteImage(session.imageId);
          return;
        }

        final slicedSvg = MarkdownRasterizer.sliceSvgViewport(
          session.cachedSvg!,
          srcY: clampedSrcY,
          srcWidth: imgW,
          srcHeight: clippedH,
        );
        pngBytes = await markdownRasterizer.rasterizeSvg(slicedSvg);
        displayCols = widthCols;
        displayRows = (clippedH / pixelsPerRow).round().clamp(1, heightRows);
      } else {
        pngBytes = await markdownRasterizer.rasterizeSvg(session.cachedSvg!);
        displayCols = widthCols;
        displayRows = null;
      }
    } else if (pngBytes.isNotEmpty) {
      // Standalone images / SVGs: fit within viewport box preserving aspect ratio
      if (imgW > 0 && imgH > 0) {
        // Terminal cell geometry: 1 col ~= 2 rows in pixel height
        final estimatedRows = (imgH / imgW) * (widthCols * 0.5);
        if (estimatedRows > heightRows) {
          displayRows = heightRows;
          displayCols = null;
        } else {
          displayCols = widthCols;
          displayRows = null;
        }
      } else {
        displayCols = widthCols;
        displayRows = null;
      }
    }

    if (pngBytes.isEmpty) {
      await kittyGraphics.deleteImage(session.imageId);
      return;
    }

    await kittyGraphics.displayPng(
      imageBytes: pngBytes,
      imageId: session.imageId,
      columns: displayCols,
      rows: displayRows,
      screenRow: screenRow,
      screenCol: screenCol,
      zIndex: 1,
    );
  }

  Future<String> _resolveAbsolutePath(String path) async {
    final file = File(path);
    if (file.isAbsolute) return path;
    try {
      final cwd = await nvim.getCwd();
      final joined = '$cwd/$path';
      if (File(joined).existsSync()) return joined;
    } catch (_) {}
    return path;
  }

  Future<List<int>> _loadImageAsPng(String filePath) async {
    final custom = _customImageLoader;
    if (custom != null) {
      return custom(filePath);
    }

    final file = File(filePath);
    if (!file.existsSync()) return const [];

    final lower = filePath.toLowerCase();
    if (lower.endsWith('.png')) {
      return file.readAsBytesSync();
    }

    // Convert JPG, WEBP, GIF, etc. to PNG using macOS sips
    if (Platform.isMacOS) {
      try {
        final tmpFile = File('${Directory.systemTemp.path}/vibrainium_${DateTime.now().microsecondsSinceEpoch}.png');
        final res = await Process.run('sips', ['-s', 'format', 'png', filePath, '--out', tmpFile.path]);
        if (res.exitCode == 0 && tmpFile.existsSync()) {
          final bytes = tmpFile.readAsBytesSync();
          tmpFile.deleteSync();
          return bytes;
        }
      } catch (_) {}
    }

    return const [];
  }

  Future<List<int>> _rasterizeSvgFile(String filePath) async {
    final custom = _customImageLoader;
    if (custom != null) {
      return custom(filePath);
    }

    final file = File(filePath);
    if (!file.existsSync()) return const [];

    try {
      final svgContent = file.readAsStringSync();
      final process = await Process.start(markdownRasterizer.resvgExecutable, ['--quiet', '-', '-c']);
      process.stdin.write(svgContent);
      await process.stdin.flush();
      await process.stdin.close();

      final chunks = <List<int>>[];
      await for (final chunk in process.stdout) {
        chunks.add(chunk);
      }
      final exitCode = await process.exitCode;
      if (exitCode == 0 && chunks.isNotEmpty) {
        return chunks.expand((x) => x).toList();
      }
    } catch (_) {}

    return const [];
  }

  Future<List<String>> _getSourceLines(int buf, PreviewType type) async {
    if (type == PreviewType.markdown) {
      return nvim.bufGetLines(buf);
    }
    // For images / SVGs, 20 lines provides a scroll viewport
    return List.filled(20, '');
  }
}
