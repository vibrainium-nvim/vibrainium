import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:nvim/nvim.dart';

/// Handles encoding and sending Kitty Graphics Protocol escape sequences
/// supported by modern terminal emulators like Ghostty, Kitty, and WezTerm.
class KittyGraphics {
  final FutureOr<void> Function(String sequence)? _customEmitter;
  final Nvim? nvim;

  const KittyGraphics({
    this.nvim,
    FutureOr<void> Function(String sequence)? customEmitter,
  }) : _customEmitter = customEmitter;

  /// Emits the escape sequence to the terminal.
  ///
  /// Prefers routing through [nvim.uiSend] so the active TUI terminal receives
  /// the escape sequence without depending on the daemon having its own controlling tty.
  Future<void> emit(String sequence) async {
    final customEmitter = _customEmitter;
    if (customEmitter != null) {
      await customEmitter(sequence);
      return;
    }

    if (nvim != null) {
      try {
        await nvim!.uiSend(sequence);
        return;
      } catch (_) {}
    }

    try {
      if (stdout.hasTerminal) {
        stdout.write(sequence);
        return;
      }
      if (Platform.isMacOS || Platform.isLinux) {
        final tty = File('/dev/tty');
        if (tty.existsSync()) {
          final raf = tty.openSync(mode: FileMode.writeOnlyAppend);
          try {
            raf.writeStringSync(sequence);
          } finally {
            raf.closeSync();
          }
          return;
        }
      }
    } catch (_) {
      // In headless test environments, safely ignore TTY write errors.
    }
  }

  /// Encodes PNG [imageBytes] into one or more Kitty Graphics Protocol escape sequences.
  ///
  /// Chunks the base64-encoded image into payloads of at most [chunkSize] (max 4096 bytes).
  static List<String> encodePngChunks({
    required List<int> imageBytes,
    required int imageId,
    int? columns,
    int? rows,
    int? srcX,
    int? srcY,
    int? srcWidth,
    int? srcHeight,
    int? xCellOffset,
    int? yCellOffset,
    int zIndex = 0,
    int chunkSize = 4096,
  }) {
    if (chunkSize <= 0 || chunkSize > 4096) {
      chunkSize = 4096;
    }

    final base64Payload = base64Encode(imageBytes);
    final chunks = <String>[];

    final controlParts = <String>[
      'a=T', // Transmit and display
      'f=100', // PNG format
      'i=$imageId',
      'p=1', // Stable placement ID for flicker-free atomic replacement
      'C=1', // Do not move cursor
    ];

    if (columns != null && columns > 0) controlParts.add('c=$columns');
    if (rows != null && rows > 0) controlParts.add('r=$rows');
    if (srcX != null && srcX >= 0) controlParts.add('x=$srcX');
    if (srcY != null && srcY >= 0) controlParts.add('y=$srcY');
    if (srcWidth != null && srcWidth > 0) controlParts.add('w=$srcWidth');
    if (srcHeight != null && srcHeight > 0) controlParts.add('h=$srcHeight');
    if (xCellOffset != null && xCellOffset >= 0) controlParts.add('X=$xCellOffset');
    if (yCellOffset != null && yCellOffset >= 0) controlParts.add('Y=$yCellOffset');
    if (zIndex != 0) controlParts.add('z=$zIndex');

    var offset = 0;
    var isFirst = true;

    while (offset < base64Payload.length) {
      final end = (offset + chunkSize < base64Payload.length)
          ? offset + chunkSize
          : base64Payload.length;
      final slice = base64Payload.substring(offset, end);
      final hasMore = end < base64Payload.length;

      final sb = StringBuffer('\x1b_G');
      if (isFirst) {
        sb.write(controlParts.join(','));
        sb.write(hasMore ? ',m=1;' : ',m=0;');
        isFirst = false;
      } else {
        sb.write(hasMore ? 'm=1;' : 'm=0;');
      }
      sb.write(slice);
      sb.write('\x1b\\');

      chunks.add(sb.toString());
      offset = end;
    }

    if (chunks.isEmpty) {
      chunks.add('\x1b_G${controlParts.join(',')},m=0;\x1b\\');
    }

    return chunks;
  }

  /// Encodes a command to delete a specific image by [imageId].
  static String encodeDeleteImage(int imageId) {
    return '\x1b_Ga=d,d=i,i=$imageId\x1b\\';
  }

  /// Encodes a command to delete all images placed by the Kitty graphics protocol.
  static String encodeDeleteAll() {
    return '\x1b_Ga=d,d=a\x1b\\';
  }

  /// Transmits and displays a PNG image at the given cell coordinates.
  ///
  /// When [screenRow] and [screenCol] are provided, saves the terminal cursor,
  /// jumps to the cell `(screenRow + 1, screenCol + 1)`, transmits the image with `C=1`,
  /// and restores the terminal cursor to prevent disrupting Neovim's cursor.
  Future<void> displayPng({
    required List<int> imageBytes,
    required int imageId,
    int? columns,
    int? rows,
    int? srcX,
    int? srcY,
    int? srcWidth,
    int? srcHeight,
    int? screenRow,
    int? screenCol,
    int? xCellOffset,
    int? yCellOffset,
    int zIndex = 0,
  }) async {
    final prefix = (screenRow != null && screenCol != null)
        ? '\x1b[s\x1b[${screenRow + 1};${screenCol + 1}H'
        : '';
    final suffix = (screenRow != null && screenCol != null) ? '\x1b[u' : '';

    final chunks = encodePngChunks(
      imageBytes: imageBytes,
      imageId: imageId,
      columns: columns,
      rows: rows,
      srcX: srcX,
      srcY: srcY,
      srcWidth: srcWidth,
      srcHeight: srcHeight,
      xCellOffset: xCellOffset,
      yCellOffset: yCellOffset,
      zIndex: zIndex,
    );

    if (chunks.isEmpty) return;

    if (chunks.length == 1) {
      await emit('$prefix${chunks.first}$suffix');
    } else {
      await emit('$prefix${chunks.first}');
      for (var i = 1; i < chunks.length - 1; i++) {
        await emit(chunks[i]);
      }
      await emit('${chunks.last}$suffix');
    }
  }

  /// Removes an image by [imageId].
  Future<void> deleteImage(int imageId) async {
    await emit(encodeDeleteImage(imageId));
  }

  /// Removes all displayed images.
  Future<void> deleteAll() async {
    await emit(encodeDeleteAll());
  }
}
