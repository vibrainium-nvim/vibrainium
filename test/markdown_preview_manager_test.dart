import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:vibrainium/vibrainium.dart';

class _FakeNvimServer {
  final StreamController<List<int>> _toClient = StreamController<List<int>>();
  final StreamController<List<int>> _fromClient = StreamController<List<int>>();
  late final RpcSession serverSession;
  late final RpcSession clientSession;

  int _nextBuf = 1;
  int _nextWin = 100;
  final Map<int, List<String>> bufLines = {};
  final Map<int, String> bufNames = {};
  final Map<int, Map<String, Object?>> bufOptions = {};
  final Map<int, Map<String, Object?>> winOptions = {};
  final Map<String, Object?> globalOptions = {};
  final Map<String, Map<String, dynamic>> highlights = {};
  final Map<int, int> winBufs = {};
  final Map<int, int> winWidths = {};
  final Map<int, int> winHeights = {};
  final Map<int, (int, int)> winPositions = {};
  final Map<int, (int, int)> winCursors = {};
  final Map<int, int> winTopLines = {};
  final Map<int, Map<String, String>> bufKeymaps = {};
  final Set<int> validWins = {};
  final Set<int> validBufs = {};
  final List<String> commands = [];
  final List<String> notifications = [];
  int currentWin = 1;

  _FakeNvimServer() {
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
      case 'nvim_get_current_win':
        return currentWin;
      case 'nvim_list_wins':
        return validWins.toList();
      case 'nvim_win_get_cursor':
        final w = params[0] as int;
        final cur = winCursors[w] ?? (1, 0);
        return [cur.$1, cur.$2];
      case 'nvim_win_set_cursor':
        final w = params[0] as int;
        final pos = params[1] as List<Object?>;
        winCursors[w] = (pos[0] as int, pos[1] as int);
        return null;
      case 'nvim_win_get_config':
        return <String, Object?>{'relative': ''};
      case 'nvim_win_is_valid':
        final w = params[0] as int;
        return validWins.contains(w);
      case 'nvim_buf_is_valid':
        final b = params[0] as int;
        return validBufs.contains(b);
      case 'nvim_win_get_buf':
        final w = params[0] as int;
        return winBufs[w] ?? 0;
      case 'nvim_win_set_buf':
        final w = params[0] as int;
        final b = params[1] as int;
        winBufs[w] = b;
        return null;
      case 'nvim_win_get_width':
        final w = params[0] as int;
        return winWidths[w] ?? 80;
      case 'nvim_win_get_height':
        final w = params[0] as int;
        return winHeights[w] ?? 24;
      case 'nvim_win_get_position':
        final w = params[0] as int;
        final pos = winPositions[w] ?? (0, 0);
        return [pos.$1, pos.$2];
      case 'nvim_win_close':
        final w = params[0] as int;
        validWins.remove(w);
        winBufs.remove(w);
        return null;
      case 'nvim_call_function':
        final fn = params[0] as String;
        final args = params[1] as List<Object?>;
        if (fn == 'getcwd') {
          return '/project';
        }
        if (fn == 'line' && args.length >= 2 && args[0] == 'w0') {
          final w = args[1] as int;
          return winTopLines[w] ?? 1;
        }
        if (fn == 'win_execute' && args.length >= 2) {
          final w = args[0] as int;
          final cmd = args[1].toString();
          final match = RegExp(r'(\d+)Gzt').firstMatch(cmd);
          if (match != null) {
            winTopLines[w] = int.parse(match.group(1)!);
          }
          return null;
        }
        return null;
      case 'nvim_ui_send':
        return null;
      case 'nvim_create_buf':
        while (validBufs.contains(_nextBuf)) {
          _nextBuf++;
        }
        final id = _nextBuf++;
        validBufs.add(id);
        bufLines[id] = [];
        bufOptions[id] = {};
        return id;
      case 'nvim_buf_get_lines':
        final b = params[0] as int;
        return bufLines[b] ?? <String>[];
      case 'nvim_buf_set_lines':
        final b = params[0] as int;
        final lines = (params[4] as List<Object?>).map((e) => e.toString()).toList();
        bufLines[b] = lines;
        return null;
      case 'nvim_buf_get_name':
        final b = params[0] as int;
        return bufNames[b] ?? '';
      case 'nvim_buf_set_name':
        final b = params[0] as int;
        bufNames[b] = params[1].toString();
        return null;
      case 'nvim_set_option_value':
        final name = params[0] as String;
        final val = params[1];
        final opts = params[2] as Map?;
        final b = opts?['buf'] as int? ?? 0;
        final w = opts?['win'] as int? ?? 0;
        if (b > 0) {
          bufOptions[b] ??= {};
          bufOptions[b]![name] = val;
        }
        if (w > 0) {
          winOptions[w] ??= {};
          winOptions[w]![name] = val;
        }
        return null;
      case 'nvim_get_option_value':
        final name = params[0] as String;
        final opts = params[1] as Map?;
        final b = opts?['buf'] as int? ?? 0;
        final w = opts?['win'] as int? ?? 0;
        if (b > 0) {
          return bufOptions[b]?[name];
        }
        if (w > 0) {
          return winOptions[w]?[name];
        }
        return globalOptions[name];
      case 'nvim_get_hl':
        final opts = params[1] as Map?;
        final name = opts?['name'] as String?;
        if (name != null) {
          return highlights[name];
        }
        return highlights;
      case 'nvim_buf_set_keymap':
        final b = params[0] as int;
        final lhs = params[2].toString();
        final rhs = params[3].toString();
        bufKeymaps[b] ??= {};
        bufKeymaps[b]![lhs] = rhs;
        return null;
      case 'nvim_notify':
        notifications.add(params[0].toString());
        return null;
      case 'nvim_command':
        final cmd = params[0].toString();
        commands.add(cmd);
        if (cmd == 'rightbelow vsplit') {
          final newWin = _nextWin++;
          validWins.add(newWin);
          winBufs[newWin] = winBufs[currentWin] ?? 0;
          winWidths[newWin] = 40;
          winHeights[newWin] = 24;
          winPositions[newWin] = (0, 40);
          currentWin = newWin;
        } else if (cmd.startsWith('bdelete!')) {
          final match = RegExp(r'bdelete!\s+(\d+)').firstMatch(cmd);
          if (match != null) {
            final b = int.parse(match.group(1)!);
            validBufs.remove(b);
          }
        }
        return null;
      default:
        return null;
    }
  }

  void dispose() {
    serverSession.close();
    clientSession.close();
    _toClient.close();
    _fromClient.close();
  }
}

void main() {
  group('BufferPreviewManager', () {
    late _FakeNvimServer fake;
    late Nvim nvim;
    late List<String> emittedSequences;
    late KittyGraphics kitty;
    late MarkdownRasterizer rasterizer;
    late BufferPreviewManager manager;

    setUp(() {
      fake = _FakeNvimServer();
      nvim = Nvim(fake.clientSession);
      emittedSequences = [];
      kitty = KittyGraphics(customEmitter: emittedSequences.add);
      rasterizer = MarkdownRasterizer(
        customRasterizer: (svg) async => [0x89, 0x50, 0x4E, 0x47],
      );
      manager = BufferPreviewManager(
        nvim: nvim,
        kittyGraphics: kitty,
        markdownRasterizer: rasterizer,
        customImageLoader: (path) async => [0x89, 0x50, 0x4E, 0x47, 0x01, 0x02],
      );

      // Setup window 1 with a markdown buffer (id: 1)
      fake.validWins.add(1);
      fake.winBufs[1] = 1;
      fake.validBufs.add(1);
      fake.bufNames[1] = '/project/README.md';
      fake.bufOptions[1] = {'filetype': 'markdown'};
      fake.bufLines[1] = ['# Title', 'Some text'];
      fake.winWidths[1] = 80;
      fake.winHeights[1] = 24;
      fake.winPositions[1] = (0, 0);
      fake.currentWin = 1;
    });

    tearDown(() {
      fake.dispose();
    });

    test('resolvePreviewType identifies markdown, images, and svg', () async {
      expect(await manager.resolvePreviewType(1), equals(PreviewType.markdown));

      fake.bufNames[2] = '/assets/logo.png';
      fake.bufOptions[2] = {};
      expect(await manager.resolvePreviewType(2), equals(PreviewType.image));

      fake.bufNames[3] = '/assets/icon.svg';
      fake.bufOptions[3] = {};
      expect(await manager.resolvePreviewType(3), equals(PreviewType.svg));

      fake.bufNames[4] = '/src/main.dart';
      fake.bufOptions[4] = {'filetype': 'dart'};
      expect(await manager.resolvePreviewType(4), equals(PreviewType.unsupported));
    });

    test('toggleInPlace toggles Markdown to Render Mode and back to Editor Mode preserving cursor', () async {
      expect(manager.isPreviewWin(1), isFalse);
      fake.winCursors[1] = (7, 15);

      // 1. Enter Render Mode
      await manager.toggleInPlace();
      expect(manager.isPreviewWin(1), isTrue);
      expect(manager.getPreviewTitle(1), contains('Preview: README.md'));

      final scratchBuf = fake.winBufs[1];
      expect(scratchBuf, isNot(equals(1))); // Swapped to scratch buffer
      expect(fake.bufOptions[scratchBuf]?['filetype'], equals('vibrainium-preview'));
      expect(emittedSequences, isNotEmpty);
      expect(emittedSequences.last, contains('a=T'));
      expect(emittedSequences.last, contains('f=100'));

      // 2. Toggle back to Editor Mode
      await manager.toggleInPlace();
      expect(manager.isPreviewWin(1), isFalse);
      expect(fake.winBufs[1], equals(1)); // Restored original buffer
      expect(fake.winCursors[1], equals((7, 15))); // Cursor position restored!
      expect(emittedSequences.last, contains('a=d,d=i'));
    });

    test('openSplitPreview reuses existing editor split when available', () async {
      // Create a second valid editor window
      fake.validWins.add(2);
      fake.validBufs.add(3);
      fake.winBufs[2] = 3;
      fake.bufNames[3] = '/src/lib.dart';
      fake.bufOptions[3] = {'filetype': 'dart'};

      final commandsBefore = fake.commands.length;
      await manager.openSplitPreview();

      // Should reuse window 2 without running 'rightbelow vsplit'
      expect(fake.commands.length, equals(commandsBefore));
      expect(manager.isPreviewWin(2), isTrue);
      expect(fake.bufOptions[fake.winBufs[2]]?['filetype'], equals('vibrainium-preview'));
    });

    test('openSplitPreview creates split when no other editor split exists', () async {
      // Setup image buffer
      fake.validBufs.add(2);
      fake.bufNames[2] = '/assets/banner.png';
      fake.bufOptions[2] = {};
      fake.winBufs[1] = 2;

      await manager.openSplitPreview();

      expect(fake.commands, contains('rightbelow vsplit'));
      final previewWin = fake.currentWin;
      expect(previewWin, isNot(equals(1)));
      expect(manager.isPreviewWin(previewWin), isTrue);
      expect(emittedSequences.last, contains('a=T'));

      // Close split
      fake.currentWin = 1;
      await manager.openSplitPreview();
      expect(manager.isPreviewWin(previewWin), isFalse);
      expect(emittedSequences.last, contains('a=d,d=i'));
    });

    test('shows warning when preview is requested on unsupported filetype', () async {
      fake.validBufs.add(5);
      fake.bufNames[5] = '/src/code.dart';
      fake.bufOptions[5] = {'filetype': 'dart'};
      fake.winBufs[1] = 5;

      await manager.openSplitPreview();

      expect(fake.notifications, isNotEmpty);
      expect(fake.notifications.last, contains('No preview available'));
      expect(manager.isPreviewWin(1), isFalse);
    });

    test('onSourceBufferChanged re-renders active preview session', () async {
      await manager.toggleInPlace();
      final countBefore = emittedSequences.length;

      // Update markdown text
      fake.bufLines[1] = ['# Updated Title', 'New content'];
      await manager.onSourceBufferChanged(1);

      expect(emittedSequences.length, greaterThan(countBefore));
      expect(emittedSequences.last, contains('a=T'));
    });

    test('openSplitPreview sets clean window options without line numbers', () async {
      await manager.openSplitPreview();
      final previewWin = fake.currentWin;
      expect(fake.winOptions[previewWin]?['number'], equals(false));
      expect(fake.winOptions[previewWin]?['relativenumber'], equals(false));
      expect(fake.winOptions[previewWin]?['signcolumn'], equals('no'));
    });

    test('syncAll updates graphic placement when split window is resized', () async {
      await manager.openSplitPreview();
      final previewWin = fake.currentWin;
      final countBefore = emittedSequences.length;

      // Simulate split border dragged to resize width
      fake.winWidths[previewWin] = 60;
      await manager.syncAll(immediate: true);

      expect(emittedSequences.length, greaterThan(countBefore));
      expect(emittedSequences.last, contains('c=60'));
      expect(emittedSequences.last, contains(',r='));
    });

    test('closeAllPreviews cleans up all images', () async {
      await manager.toggleInPlace();
      await manager.closeAllPreviews();

      expect(manager.isPreviewWin(1), isFalse);
      expect(emittedSequences.last, equals('\x1b_Ga=d,d=a\x1b\\'));
    });

    test('resolveMarkdownTheme and markdown preview inherit Neovim colorscheme', () async {
      fake.globalOptions['background'] = 'light';
      fake.highlights['Normal'] = {'fg': 0x4c4f69, 'bg': 0xeff1f5};
      fake.highlights['Title'] = {'fg': 0x1e66f5};
      fake.highlights['Comment'] = {'fg': 0xacb0be};

      final resolvedTheme = await manager.resolveMarkdownTheme();
      expect(resolvedTheme.bgColor, '#eff1f5');
      expect(resolvedTheme.textColor, '#4c4f69');
      expect(resolvedTheme.h1Color, '#1e66f5');
      expect(resolvedTheme.blockquoteBorder, '#acb0be');

      String? capturedSvg;
      final themeRasterizer = MarkdownRasterizer(
        customRasterizer: (svg) async {
          capturedSvg = svg;
          return [0x89, 0x50, 0x4E, 0x47];
        },
      );
      final themedManager = BufferPreviewManager(
        nvim: nvim,
        kittyGraphics: kitty,
        markdownRasterizer: themeRasterizer,
      );

      await themedManager.toggleInPlace();
      expect(capturedSvg, isNotNull);
      expect(capturedSvg, contains('fill="#eff1f5"'));
      expect(capturedSvg, contains('fill="#4c4f69"'));
    });

    test('scrolling updates SVG viewBox viewport without relying on Kitty x/y/w/h crop', () async {
      // Generate enough markdown lines so rendered SVG is tall (> 1000px)
      fake.bufLines[1] = List.generate(80, (i) => 'Paragraph line $i');
      String? lastSlicedSvg;
      final scrollRasterizer = MarkdownRasterizer(
        customRasterizer: (svg) async {
          lastSlicedSvg = svg;
          return [0x89, 0x50, 0x4E, 0x47];
        },
      );
      final scrollManager = BufferPreviewManager(
        nvim: nvim,
        kittyGraphics: kitty,
        markdownRasterizer: scrollRasterizer,
      );

      await scrollManager.toggleInPlace();
      expect(lastSlicedSvg, isNotNull);

      final fullSvg = scrollRasterizer.markdownToSvg(
        fake.bufLines[1]!.join('\n'),
        widthPx: 800,
      );
      final fullDims = MarkdownRasterizer.parseSvgDimensions(fullSvg)!;
      final pixelsPerRow = (2.0 * fullDims.$1) / 80; // 20px
      final expectedVirtualRows = (fullDims.$2 / pixelsPerRow).ceil();

      final scratchBuf = fake.winBufs[1]!;
      expect(fake.bufLines[scratchBuf]!.length, equals(expectedVirtualRows + 10));
      // Initial render at topLine=1 -> viewBox="0 0 800 ..." and r=24
      expect(lastSlicedSvg, contains('viewBox="0 0 ${fullDims.$1} '));
      expect(emittedSequences.last, contains('c=80'));
      expect(emittedSequences.last, contains('r=24'));

      // Scroll down to topLine = 11 -> srcY = 10 * 20 = 200
      fake.winTopLines[1] = 11;
      await scrollManager.syncAll(immediate: true);

      expect(lastSlicedSvg, contains('viewBox="0 200 ${fullDims.$1} '));
      expect(emittedSequences.last, contains('r=24'));
    });

    test('winbar offset shifts preview graphic below the tab bar row', () async {
      fake.winOptions[1] = {'winbar': '%#VibrainiumTabActive# README.md %*'};
      await manager.toggleInPlace();

      // Window position is (0, 0) with winbar=1 -> graphic must start at 0-based row 1 (ANSI row 2)
      expect(emittedSequences.last, contains('\x1b[2;1H'));
    });

    test('preview buffer binds navigation keymaps for smooth scrolling', () async {
      await manager.toggleInPlace();
      final scratchBuf = fake.winBufs[1]!;
      final keymaps = fake.bufKeymaps[scratchBuf];
      expect(keymaps, isNotNull);
      expect(keymaps!['j'], equals('<C-e>'));
      expect(keymaps['k'], equals('<C-y>'));
      expect(keymaps['<Down>'], equals('<C-e>'));
      expect(keymaps['<Up>'], equals('<C-y>'));
      expect(keymaps['<Space>'], equals('<C-f>'));
      expect(keymaps['gg'], isNotNull);
      expect(keymaps['G'], isNotNull);
      expect(keymaps['q'], contains('VibrainiumBufferPreviewToggle'));
    });

    test('split preview proportionally scrolls when source editor window scrolls', () async {
      // Source buffer with 101 lines
      fake.bufLines[1] = List.generate(101, (i) => 'Line $i');
      fake.winTopLines[1] = 1;

      String? lastSlicedSvg;
      final splitRasterizer = MarkdownRasterizer(
        customRasterizer: (svg) async {
          lastSlicedSvg = svg;
          return [0x89, 0x50, 0x4E, 0x47];
        },
      );
      final splitManager = BufferPreviewManager(
        nvim: nvim,
        kittyGraphics: kitty,
        markdownRasterizer: splitRasterizer,
      );

      await splitManager.openSplitPreview();
      final previewWin = fake.currentWin;
      expect(previewWin, isNot(equals(1)));
      expect(fake.winTopLines[previewWin] ?? 1, equals(1));

      // Scroll source editor window to halfway (line 51 of 101 -> ratio 0.5)
      fake.winTopLines[1] = 51;
      await splitManager.syncAll(immediate: true);

      final targetTop = fake.winTopLines[previewWin]!;
      expect(targetTop, greaterThan(1));
      // Preview window is 40 cols, widthPx = 600 -> pixelsPerRow = (2*600)/40 = 30px
      final expectedSrcY = ((targetTop - 1) * 30.0).round();
      expect(lastSlicedSvg, contains('viewBox="0 $expectedSrcY 600 '));
    });

    test('opening another file in the preview window detaches preview session and cleans up graphic', () async {
      await manager.toggleInPlace();
      expect(manager.isPreviewWin(1), isTrue);

      // User opens a different file (buf 10) in the same window
      fake.validBufs.add(10);
      fake.bufNames[10] = '/project/main.dart';
      fake.bufOptions[10] = {'filetype': 'dart'};
      fake.winBufs[1] = 10;

      await manager.pruneStaleSessions();

      expect(manager.isPreviewWin(1), isFalse);
      expect(fake.winBufs[1], equals(10));
      expect(emittedSequences.last, contains('a=d,d=i'));
    });

    test('EditorTabbar preserves original file tabs during in-place preview and shows Preview title for split preview', () async {
      // Open a second file (buf 10) first so window 1 has 2 tabs
      fake.validBufs.add(10);
      fake.bufNames[10] = '/project/main.dart';
      fake.bufOptions[10] = {'filetype': 'dart'};

      final tabbar = EditorTabbar(
        nvim: nvim,
        nonEditorFiletypes: const {'vibrainium-preview'},
        isPanelWin: (w) => manager.isSplitPreviewWin(w),
        isPreviewWin: manager.isSplitPreviewWin,
        getPreviewTitle: manager.getPreviewTitle,
      );

      await tabbar.sync(); // records README.md
      fake.winBufs[1] = 10;
      await tabbar.sync(); // records main.dart
      fake.winBufs[1] = 1; // switch back to README.md
      await tabbar.sync();

      final originalWinbar = fake.winOptions[1]?['winbar']?.toString() ?? '';
      expect(originalWinbar, contains('README.md'));
      expect(originalWinbar, contains('main.dart'));

      // Toggle in-place preview -> winbar must remain the exact original tabbar
      // even if Neovim clears window-local winbar on nvim_win_set_buf.
      await manager.toggleInPlace();
      fake.winOptions[1]?['winbar'] = '';
      expect(manager.isPreviewWin(1), isTrue);
      expect(manager.isSplitPreviewWin(1), isFalse);

      await tabbar.sync();
      expect(fake.winOptions[1]?['winbar'], equals(originalWinbar));

      // Toggle back and open split preview -> split window shows Preview title
      await manager.toggleInPlace();
      await manager.openSplitPreview();
      final previewWin = fake.currentWin;
      expect(manager.isSplitPreviewWin(previewWin), isTrue);
      await tabbar.sync();
      expect(fake.winOptions[previewWin]?['winbar']?.toString(), contains('Preview'));
    });

    test('scroll updates replace placement in-place without eager deleteImage flicker', () async {
      await manager.toggleInPlace();
      expect(manager.isPreviewWin(1), isTrue);

      emittedSequences.clear();
      fake.winTopLines[1] = 5;
      await manager.syncAll(immediate: true);

      expect(emittedSequences.any((s) => s.contains('a=d,d=i')), isFalse);
      expect(emittedSequences.any((s) => s.contains('a=T') && s.contains('p=1')), isTrue);
    });

    test('switching tabs away and back restores suspended in-place preview unless explicitly toggled off', () async {
      fake.validBufs.add(10);
      fake.bufNames[10] = '/project/main.dart';
      fake.bufOptions[10] = {'filetype': 'dart'};

      await manager.toggleInPlace();
      expect(manager.isPreviewWin(1), isTrue);
      final scratchBuf = fake.winBufs[1]!;
      expect(scratchBuf, isNot(equals(1)));

      // Switch tab to main.dart (buf 10) -> detaches preview & deletes Kitty image
      fake.winBufs[1] = 10;
      await manager.pruneStaleSessions();
      expect(manager.isPreviewWin(1), isFalse);
      expect(emittedSequences.last, contains('a=d,d=i'));

      // Switch back to README.md (buf 1) -> restores in-place preview automatically
      fake.winBufs[1] = 1;
      await manager.pruneStaleSessions();
      expect(manager.isPreviewWin(1), isTrue);

      // Explicitly toggle off -> switching away and back does NOT re-open preview
      await manager.toggleInPlace();
      expect(manager.isPreviewWin(1), isFalse);
      expect(fake.winBufs[1], equals(1));

      fake.winBufs[1] = 10;
      await manager.pruneStaleSessions();
      fake.winBufs[1] = 1;
      await manager.pruneStaleSessions();
      expect(manager.isPreviewWin(1), isFalse);
    });
  });
}
