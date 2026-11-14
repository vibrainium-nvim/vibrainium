import 'dart:convert';
import 'dart:io';

import 'markdown_theme.dart';

/// Converts Markdown text into a styled, high-DPI vector SVG and rasterizes it
/// to PNG bytes using an SVG rasterizer like `resvg`.
class MarkdownRasterizer {
  final String resvgExecutable;
  final Future<List<int>> Function(String svgString)? _customRasterizer;

  const MarkdownRasterizer({
    this.resvgExecutable = 'resvg',
    Future<List<int>> Function(String svgString)? customRasterizer,
  }) : _customRasterizer = customRasterizer;

  /// Converts [markdown] content into a standalone SVG document string.
  ///
  /// [widthPx] is the rendered canvas width in pixels (e.g. 800-1400px).
  /// [themeDark] specifies whether to use dark mode or light mode when [theme] is not provided.
  /// [theme] provides custom colors derived from Neovim or another theme provider.
  String markdownToSvg(
    String markdown, {
    int widthPx = 960,
    bool themeDark = true,
    MarkdownTheme? theme,
  }) {
    final activeTheme =
        theme ?? (themeDark ? MarkdownTheme.dark : MarkdownTheme.light);
    final bgColor = activeTheme.bgColor;
    final textColor = activeTheme.textColor;
    final h1Color = activeTheme.h1Color;
    final h2Color = activeTheme.h2Color;
    final h3Color = activeTheme.h3Color;
    final codeBg = activeTheme.codeBg;
    final codeColor = activeTheme.codeColor;
    final blockquoteBorder = activeTheme.blockquoteBorder;
    final tableBorder = activeTheme.tableBorder;
    final tableHeaderBg = activeTheme.tableHeaderBg;
    final linkColor = activeTheme.linkColor;

    String format(String text, String defaultColor) => _formatInline(
          text,
          defaultColor: defaultColor,
          codeColor: codeColor,
          linkColor: linkColor,
        );

    final lines = LineSplitter.split(markdown).toList();
    final bodySvg = StringBuffer();

    var currentY = 40.0;
    const paddingX = 40.0;
    final contentWidth = widthPx - (paddingX * 2);
    // Average character width for 14px font is ~8.5px
    final baseMaxChars = (contentWidth / 8.5).floor().clamp(20, 160);

    var inCodeBlock = false;
    final codeBlockLines = <String>[];
    String? codeLang;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      // Code blocks (```)
      if (trimmed.startsWith('```')) {
        if (!inCodeBlock) {
          inCodeBlock = true;
          codeLang = trimmed.substring(3).trim();
          codeBlockLines.clear();
        } else {
          inCodeBlock = false;
          // Render accumulated code block
          final blockHeight = (codeBlockLines.length * 22.0) + 36.0;
          bodySvg.write('''
  <rect x="$paddingX" y="$currentY" width="$contentWidth" height="$blockHeight" rx="8" ry="8" fill="$codeBg" stroke="$tableBorder" stroke-width="1"/>
''');
          if (codeLang != null && codeLang.isNotEmpty) {
            bodySvg.write('''
  <text x="${paddingX + contentWidth - 16}" y="${currentY + 20}" font-family="monospace" font-size="11" fill="$blockquoteBorder" text-anchor="end">${_escapeXml(codeLang)}</text>
''');
          }
          var codeLineY = currentY + 26.0;
          for (final codeLine in codeBlockLines) {
            bodySvg.write('''
  <text x="${paddingX + 16}" y="$codeLineY" font-family="monospace" font-size="13" fill="$codeColor">${_escapeXml(codeLine)}</text>
''');
            codeLineY += 22.0;
          }
          currentY += blockHeight + 16.0;
        }
        continue;
      }

      if (inCodeBlock) {
        codeBlockLines.add(line);
        continue;
      }

      // Empty line / paragraph break
      if (trimmed.isEmpty) {
        currentY += 14.0;
        continue;
      }

      // Horizontal Rule
      if (trimmed == '---' || trimmed == '***' || trimmed == '___') {
        currentY += 10.0;
        bodySvg.write('''
  <line x1="$paddingX" y1="$currentY" x2="${paddingX + contentWidth}" y2="$currentY" stroke="$tableBorder" stroke-width="1"/>
''');
        currentY += 18.0;
        continue;
      }

      // Headings
      if (trimmed.startsWith('# ')) {
        final text = trimmed.substring(2);
        currentY += 14.0;
        final tspans = format(text, h1Color);
        bodySvg.write('''
  <text x="$paddingX" y="$currentY" font-family="system-ui, -apple-system, sans-serif" font-size="28" font-weight="bold" fill="$h1Color">$tspans</text>
''');
        currentY += 12.0;
        bodySvg.write('''
  <line x1="$paddingX" y1="$currentY" x2="${paddingX + contentWidth}" y2="$currentY" stroke="$tableBorder" stroke-width="1"/>
''');
        currentY += 26.0;
        continue;
      }

      if (trimmed.startsWith('## ')) {
        final text = trimmed.substring(3);
        currentY += 10.0;
        final tspans = format(text, h2Color);
        bodySvg.write('''
  <text x="$paddingX" y="$currentY" font-family="system-ui, -apple-system, sans-serif" font-size="22" font-weight="bold" fill="$h2Color">$tspans</text>
''');
        currentY += 24.0;
        continue;
      }

      if (trimmed.startsWith('### ')) {
        final text = trimmed.substring(4);
        currentY += 8.0;
        final tspans = format(text, h3Color);
        bodySvg.write('''
  <text x="$paddingX" y="$currentY" font-family="system-ui, -apple-system, sans-serif" font-size="18" font-weight="600" fill="$h3Color">$tspans</text>
''');
        currentY += 22.0;
        continue;
      }

      // Blockquote
      if (trimmed.startsWith('> ')) {
        final text = trimmed.substring(2);
        final wrapped = _wrapWords(text, (baseMaxChars - 4).clamp(15, 150));
        final blockHeight = (wrapped.length * 20.0) + 4.0;
        bodySvg.write('''
  <line x1="$paddingX" y1="${currentY - 14}" x2="$paddingX" y2="${currentY + blockHeight - 16}" stroke="$blockquoteBorder" stroke-width="4" stroke-linecap="round"/>
''');
        for (final wLine in wrapped) {
          final tspans = format(wLine, blockquoteBorder);
          bodySvg.write('''
  <text x="${paddingX + 16}" y="$currentY" font-family="system-ui, -apple-system, sans-serif" font-size="14" font-style="italic" fill="$blockquoteBorder">$tspans</text>
''');
          currentY += 20.0;
        }
        currentY += 6.0;
        continue;
      }

      // Bullet lists
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
        final text = trimmed.substring(2);
        final listMaxChars = (baseMaxChars - 4).clamp(15, 150);
        final wrapped = _wrapWords(text, listMaxChars);

        bodySvg.write('''
  <circle cx="${paddingX + 8}" cy="${currentY - 4}" r="3" fill="$h1Color"/>
''');
        for (var idx = 0; idx < wrapped.length; idx++) {
          final tspans = format(wrapped[idx], textColor);
          bodySvg.write('''
  <text x="${paddingX + 22}" y="$currentY" font-family="system-ui, -apple-system, sans-serif" font-size="14" fill="$textColor">$tspans</text>
''');
          currentY += 20.0;
        }
        currentY += 2.0;
        continue;
      }

      // Numbered lists
      final numMatch = RegExp(r'^(\d+)\.\s+(.*)$').firstMatch(trimmed);
      if (numMatch != null) {
        final num = numMatch.group(1);
        final text = numMatch.group(2) ?? '';
        final listMaxChars = (baseMaxChars - 5).clamp(15, 150);
        final wrapped = _wrapWords(text, listMaxChars);

        bodySvg.write('''
  <text x="${paddingX + 4}" y="$currentY" font-family="system-ui, -apple-system, sans-serif" font-size="13" font-weight="bold" fill="$h2Color">$num.</text>
''');
        for (var idx = 0; idx < wrapped.length; idx++) {
          final tspans = format(wrapped[idx], textColor);
          bodySvg.write('''
  <text x="${paddingX + 26}" y="$currentY" font-family="system-ui, -apple-system, sans-serif" font-size="14" fill="$textColor">$tspans</text>
''');
          currentY += 20.0;
        }
        currentY += 2.0;
        continue;
      }

      // Table row (simple detection)
      if (trimmed.startsWith('|') && trimmed.endsWith('|')) {
        final cells = trimmed
            .split('|')
            .where((c) => c.isNotEmpty)
            .map((c) => c.trim())
            .toList();
        if (cells.every((c) => RegExp(r'^-+$').hasMatch(c))) {
          // Separator row
          continue;
        }
        final isHeader = (i + 1 < lines.length &&
            lines[i + 1].trim().startsWith('|') &&
            lines[i + 1].trim().contains('---'));
        final colWidth = contentWidth / (cells.isNotEmpty ? cells.length : 1);
        final rowHeight = 28.0;

        if (isHeader) {
          bodySvg.write('''
  <rect x="$paddingX" y="${currentY - 18}" width="$contentWidth" height="$rowHeight" fill="$tableHeaderBg"/>
''');
        }

        for (var c = 0; c < cells.length; c++) {
          final cellX = paddingX + (c * colWidth) + 8.0;
          final cellTspans = format(cells[c], isHeader ? h1Color : textColor);
          bodySvg.write('''
  <text x="$cellX" y="$currentY" font-family="system-ui, -apple-system, sans-serif" font-size="13" font-weight="${isHeader ? 'bold' : 'normal'}" fill="${isHeader ? h1Color : textColor}">$cellTspans</text>
''');
        }
        currentY += rowHeight;
        continue;
      }

      // Standard body paragraph with word wrapping and inline formatting
      final wrapped = _wrapWords(trimmed, baseMaxChars);
      for (final wLine in wrapped) {
        final tspans = format(wLine, textColor);
        bodySvg.write('''
  <text x="$paddingX" y="$currentY" font-family="system-ui, -apple-system, sans-serif" font-size="14" fill="$textColor">$tspans</text>
''');
        currentY += 21.0;
      }
      currentY += 4.0;
    }

    final totalHeight = currentY + 40.0;

    return '''<svg xmlns="http://www.w3.org/2000/svg" width="$widthPx" height="${totalHeight.toInt()}" viewBox="0 0 $widthPx ${totalHeight.toInt()}">
  <rect width="100%" height="100%" fill="$bgColor"/>
${bodySvg.toString()}</svg>''';
  }

  /// Rasterizes [markdown] text into PNG bytes.
  Future<List<int>> rasterizeMarkdown(
    String markdown, {
    int widthPx = 960,
    bool themeDark = true,
    MarkdownTheme? theme,
  }) async {
    final svg = markdownToSvg(
      markdown,
      widthPx: widthPx,
      themeDark: themeDark,
      theme: theme,
    );
    return rasterizeSvg(svg);
  }

  /// Rasterizes an SVG document [svgString] into PNG bytes.
  Future<List<int>> rasterizeSvg(String svgString) async {
    final customRasterizer = _customRasterizer;
    if (customRasterizer != null) {
      return customRasterizer(svgString);
    }

    try {
      final process = await Process.start(resvgExecutable, ['--quiet', '-', '-c']);
      process.stdin.write(svgString);
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
    } catch (_) {
      // In case resvg execution fails or is not available
    }

    return const <int>[];
  }

  /// Extracts integer `(width, height)` from the root `<svg>` element, if present.
  static (int, int)? parseSvgDimensions(String svgString) {
    final tagMatch = RegExp(r'<svg\b[^>]*>', caseSensitive: false).firstMatch(svgString);
    if (tagMatch == null) return null;
    final tag = tagMatch.group(0)!;
    final wMatch = RegExp(r'\bwidth="(\d+(?:\.\d+)?)"').firstMatch(tag);
    final hMatch = RegExp(r'\bheight="(\d+(?:\.\d+)?)"').firstMatch(tag);
    if (wMatch != null && hMatch != null) {
      final w = double.tryParse(wMatch.group(1)!)?.round() ?? 0;
      final h = double.tryParse(hMatch.group(1)!)?.round() ?? 0;
      if (w > 0 && h > 0) return (w, h);
    }
    final vbMatch = RegExp(
      r'\bviewBox="\s*[\d.\-]+\s+[\d.\-]+\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s*"',
    ).firstMatch(tag);
    if (vbMatch != null) {
      final w = double.tryParse(vbMatch.group(1)!)?.round() ?? 0;
      final h = double.tryParse(vbMatch.group(2)!)?.round() ?? 0;
      if (w > 0 && h > 0) return (w, h);
    }
    return null;
  }

  /// Returns a copy of [svgString] whose root `<svg>` viewport is cropped to
  /// `[0, srcY, srcWidth, srcHeight]`.
  static String sliceSvgViewport(
    String svgString, {
    required int srcY,
    required int srcWidth,
    required int srcHeight,
  }) {
    final tagMatch = RegExp(r'<svg\b([^>]*)>', caseSensitive: false).firstMatch(svgString);
    if (tagMatch == null) return svgString;
    var attrs = tagMatch.group(1)!;

    attrs = attrs.replaceAll(RegExp(r'\s*\bwidth="[^"]*"'), '');
    attrs = attrs.replaceAll(RegExp(r'\s*\bheight="[^"]*"'), '');
    attrs = attrs.replaceAll(RegExp(r'\s*\bviewBox="[^"]*"'), '');

    final newTag =
        '<svg$attrs width="$srcWidth" height="$srcHeight" viewBox="0 $srcY $srcWidth $srcHeight">';
    return svgString.replaceRange(tagMatch.start, tagMatch.end, newTag);
  }

  static List<String> _wrapWords(String text, int maxChars) {
    if (text.length <= maxChars) return [text];
    final words = text.split(' ');
    final lines = <String>[];
    var current = StringBuffer();

    for (final word in words) {
      if (current.isEmpty) {
        current.write(word);
      } else if (current.length + 1 + word.length <= maxChars) {
        current.write(' $word');
      } else {
        lines.add(current.toString());
        current = StringBuffer(word);
      }
    }
    if (current.isNotEmpty) {
      lines.add(current.toString());
    }
    return lines.isEmpty ? [text] : lines;
  }

  static String _formatInline(
    String text, {
    required String defaultColor,
    String codeColor = '#fab387',
    String linkColor = '#89b4fa',
  }) {
    final tokenPattern = RegExp(
      r'(\*\*(.+?)\*\*|\*([^\*]+?)\*|`([^`]+?)`|\[([^\]]+?)\]\(([^)]+?)\))',
    );
    final sb = StringBuffer();
    var lastIndex = 0;

    for (final match in tokenPattern.allMatches(text)) {
      if (match.start > lastIndex) {
        sb.write(_escapeXml(text.substring(lastIndex, match.start)));
      }
      if (match.group(2) != null) {
        // **bold**
        sb.write('<tspan font-weight="bold">${_escapeXml(match.group(2)!)}</tspan>');
      } else if (match.group(3) != null) {
        // *italic*
        sb.write('<tspan font-style="italic">${_escapeXml(match.group(3)!)}</tspan>');
      } else if (match.group(4) != null) {
        // `code`
        sb.write('<tspan font-family="monospace" font-size="12" fill="$codeColor">${_escapeXml(match.group(4)!)}</tspan>');
      } else if (match.group(5) != null) {
        // [label](url)
        sb.write('<tspan fill="$linkColor" text-decoration="underline">${_escapeXml(match.group(5)!)}</tspan>');
      }
      lastIndex = match.end;
    }

    if (lastIndex < text.length) {
      sb.write(_escapeXml(text.substring(lastIndex)));
    }
    return sb.toString();
  }

  static String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
