/// Color palette specification for Markdown SVG rendering.
class MarkdownTheme {
  final String bgColor;
  final String textColor;
  final String h1Color;
  final String h2Color;
  final String h3Color;
  final String codeBg;
  final String codeColor;
  final String blockquoteBorder;
  final String tableBorder;
  final String tableHeaderBg;
  final String linkColor;

  const MarkdownTheme({
    required this.bgColor,
    required this.textColor,
    required this.h1Color,
    required this.h2Color,
    required this.h3Color,
    required this.codeBg,
    required this.codeColor,
    required this.blockquoteBorder,
    required this.tableBorder,
    required this.tableHeaderBg,
    required this.linkColor,
  });

  /// Default dark theme (Catppuccin Mocha palette).
  static const dark = MarkdownTheme(
    bgColor: '#1e1e2e',
    textColor: '#cdd6f4',
    h1Color: '#89b4fa',
    h2Color: '#a6e3a1',
    h3Color: '#f9e2af',
    codeBg: '#11111b',
    codeColor: '#fab387',
    blockquoteBorder: '#585b70',
    tableBorder: '#313244',
    tableHeaderBg: '#181825',
    linkColor: '#89b4fa',
  );

  /// Default light theme (Catppuccin Latte palette).
  static const light = MarkdownTheme(
    bgColor: '#eff1f5',
    textColor: '#4c4f69',
    h1Color: '#1e66f5',
    h2Color: '#40a02b',
    h3Color: '#df8e1d',
    codeBg: '#e6e9ef',
    codeColor: '#fe640b',
    blockquoteBorder: '#acb0be',
    tableBorder: '#ccd0da',
    tableHeaderBg: '#e6e9ef',
    linkColor: '#1e66f5',
  );

  /// Builds a [MarkdownTheme] by extracting colors from Neovim highlight groups.
  ///
  /// [background] is typically `'light'` or `'dark'` (from Neovim's `&background`).
  /// [highlights] maps group names (e.g. `'Normal'`, `'Comment'`) to their attribute map
  /// containing `'fg'` and/or `'bg'` integer color values.
  static MarkdownTheme fromNvimHighlights({
    String background = 'dark',
    Map<String, Map<String, dynamic>> highlights = const {},
  }) {
    final isLight = background.trim().toLowerCase() == 'light';
    final fallback = isLight ? MarkdownTheme.light : MarkdownTheme.dark;

    String? hexFg(String group) => _intToHex(highlights[group]?['fg']);
    String? hexBg(String group) => _intToHex(highlights[group]?['bg']);

    final normalBg = hexBg('Normal');
    final normalFg = hexFg('Normal');

    final h1 = hexFg('@markup.heading.1') ??
        hexFg('Title') ??
        hexFg('Function') ??
        fallback.h1Color;

    final h2 = hexFg('@markup.heading.2') ??
        hexFg('Type') ??
        hexFg('String') ??
        fallback.h2Color;

    final h3 = hexFg('@markup.heading.3') ??
        hexFg('Special') ??
        hexFg('Constant') ??
        fallback.h3Color;

    final codeBg = hexBg('ColorColumn') ??
        hexBg('CursorLine') ??
        fallback.codeBg;

    final codeColor = hexFg('String') ??
        hexFg('Special') ??
        hexFg('Identifier') ??
        fallback.codeColor;

    final blockquoteBorder = hexFg('Comment') ?? fallback.blockquoteBorder;

    final tableBorder = hexFg('WinSeparator') ??
        hexFg('VertSplit') ??
        hexFg('Comment') ??
        fallback.tableBorder;

    final tableHeaderBg = hexBg('CursorLine') ??
        hexBg('ColorColumn') ??
        fallback.tableHeaderBg;

    final linkColor = hexFg('@markup.link.url') ??
        hexFg('Underlined') ??
        hexFg('Identifier') ??
        fallback.linkColor;

    return MarkdownTheme(
      bgColor: normalBg ?? fallback.bgColor,
      textColor: normalFg ?? fallback.textColor,
      h1Color: h1,
      h2Color: h2,
      h3Color: h3,
      codeBg: codeBg,
      codeColor: codeColor,
      blockquoteBorder: blockquoteBorder,
      tableBorder: tableBorder,
      tableHeaderBg: tableHeaderBg,
      linkColor: linkColor,
    );
  }

  static String? _intToHex(Object? value) {
    if (value is int) {
      final rgb = value & 0xFFFFFF;
      return '#${rgb.toRadixString(16).padLeft(6, '0')}';
    }
    return null;
  }
}
