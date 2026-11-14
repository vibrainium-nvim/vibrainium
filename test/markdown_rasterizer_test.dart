import 'package:test/test.dart';
import 'package:vibrainium/vibrainium.dart';

void main() {
  group('MarkdownRasterizer', () {
    const rasterizer = MarkdownRasterizer();

    test('markdownToSvg converts headings with distinct styles', () {
      const md = '''
# Heading 1
## Heading 2
### Heading 3
''';
      final svg = rasterizer.markdownToSvg(md, widthPx: 800, themeDark: true);
      expect(svg, contains('<svg'));
      expect(svg, contains('Heading 1'));
      expect(svg, contains('Heading 2'));
      expect(svg, contains('Heading 3'));
      expect(svg, contains('font-size="28"'));
      expect(svg, contains('font-size="22"'));
      expect(svg, contains('font-size="18"'));
    });

    test('markdownToSvg converts code blocks with background card', () {
      const md = '''
```dart
void main() {
  print("Hello Ghostty");
}
```
''';
      final svg = rasterizer.markdownToSvg(md, widthPx: 800, themeDark: true);
      expect(svg, contains('<rect'));
      expect(svg, contains('dart'));
      expect(svg, contains('void main() {'));
      expect(svg, contains('print(&quot;Hello Ghostty&quot;);'));
    });

    test('markdownToSvg converts bullet lists and blockquotes', () {
      const md = '''
- Item 1
- Item 2
> A blockquote message
''';
      final svg = rasterizer.markdownToSvg(md);
      expect(svg, contains('<circle'));
      expect(svg, contains('Item 1'));
      expect(svg, contains('Item 2'));
      expect(svg, contains('A blockquote message'));
      expect(svg, contains('font-style="italic"'));
    });

    test('markdownToSvg parses inline bold, italic, code, and links into styled tspans', () {
      const md = 'Here is **bold text**, *italic text*, `code snippet`, and [my link](https://vibrainium.dev).';
      final svg = rasterizer.markdownToSvg(md);
      expect(svg, contains('<tspan font-weight="bold">bold text</tspan>'));
      expect(svg, contains('<tspan font-style="italic">italic text</tspan>'));
      expect(svg, contains('<tspan font-family="monospace" font-size="12" fill="#fab387">code snippet</tspan>'));
      expect(svg, contains('<tspan fill="#89b4fa" text-decoration="underline">my link</tspan>'));
      // Raw markdown url should not be dumped into the text
      expect(svg, isNot(contains('https://vibrainium.dev')));
    });

    test('markdownToSvg wraps long sentences into multiple lines', () {
      final longSentence = List.generate(40, (i) => 'word$i').join(' ');
      final svg = rasterizer.markdownToSvg(longSentence, widthPx: 400);
      // Because width is narrow (400px), it should produce multiple <text> lines
      final textOccurrences = RegExp(r'<text\s').allMatches(svg).length;
      expect(textOccurrences, greaterThan(1));
    });

    test('markdownToSvg escapes special XML characters', () {
      const md = 'Look at <this> & "that"';
      final svg = rasterizer.markdownToSvg(md);
      expect(svg, contains('&lt;this&gt; &amp; &quot;that&quot;'));
      expect(svg, isNot(contains('<this>')));
    });

    test('rasterizeMarkdown uses custom rasterizer when provided', () async {
      final custom = MarkdownRasterizer(
        customRasterizer: (svg) async => [137, 80, 78, 71],
      );
      final bytes = await custom.rasterizeMarkdown('# Test');
      expect(bytes, equals([137, 80, 78, 71]));
    });

    test('rasterizeMarkdown runs resvg and generates valid PNG bytes', () async {
      // Test real resvg invocation on this machine
      const md = '''
# Real resvg Test
This is rendered by **resvg** on macOS.
''';
      final bytes = await rasterizer.rasterizeMarkdown(md, widthPx: 600);
      expect(bytes, isNotEmpty);
      // First 4 bytes of a PNG are 0x89 'P' 'N' 'G'
      expect(bytes.take(4).toList(), equals([0x89, 0x50, 0x4E, 0x47]));
    });

    test('markdownToSvg applies custom MarkdownTheme colors', () {
      const customTheme = MarkdownTheme(
        bgColor: '#282a36',
        textColor: '#f8f8f2',
        h1Color: '#ff79c6',
        h2Color: '#50fa7b',
        h3Color: '#8be9fd',
        codeBg: '#21222c',
        codeColor: '#ffb86c',
        blockquoteBorder: '#6272a4',
        tableBorder: '#44475a',
        tableHeaderBg: '#21222c',
        linkColor: '#bd93f9',
      );

      const md = '''
# Heading Custom
A paragraph with `code` and [link](https://example.com).
''';
      final svg = rasterizer.markdownToSvg(md, theme: customTheme);
      expect(svg, contains('fill="#282a36"'));
      expect(svg, contains('fill="#ff79c6"'));
      expect(svg, contains('fill="#ffb86c"'));
      expect(svg, contains('fill="#bd93f9"'));
      expect(svg, contains('fill="#f8f8f2"'));
    });

    test('MarkdownTheme.fromNvimHighlights resolves Neovim colors properly', () {
      final theme = MarkdownTheme.fromNvimHighlights(
        background: 'light',
        highlights: {
          'Normal': {'fg': 0x112233, 'bg': 0xfafafa},
          'Title': {'fg': 0xff0055},
          'Comment': {'fg': 0x888888},
          'String': {'fg': 0x00aa22},
          'ColorColumn': {'bg': 0xeeeeee},
          'Underlined': {'fg': 0x0000ff},
        },
      );

      expect(theme.bgColor, '#fafafa');
      expect(theme.textColor, '#112233');
      expect(theme.h1Color, '#ff0055');
      expect(theme.blockquoteBorder, '#888888');
      expect(theme.codeColor, '#00aa22');
      expect(theme.codeBg, '#eeeeee');
      expect(theme.linkColor, '#0000ff');
    });

    test('MarkdownTheme.fromNvimHighlights falls back gracefully when highlights missing', () {
      final darkTheme = MarkdownTheme.fromNvimHighlights(background: 'dark');
      expect(darkTheme.bgColor, MarkdownTheme.dark.bgColor);
      expect(darkTheme.textColor, MarkdownTheme.dark.textColor);

      final lightTheme = MarkdownTheme.fromNvimHighlights(background: 'light');
      expect(lightTheme.bgColor, MarkdownTheme.light.bgColor);
      expect(lightTheme.textColor, MarkdownTheme.light.textColor);
    });
  });
}
