import 'package:test/test.dart';
import 'package:vibrainium/vibrainium.dart';

void main() {
  group('KittyGraphics', () {
    test('encodePngChunks encodes small image in a single chunk with m=0', () {
      final fakeBytes = [1, 2, 3, 4, 5, 6, 7, 8];
      final chunks = KittyGraphics.encodePngChunks(
        imageBytes: fakeBytes,
        imageId: 42,
        columns: 80,
        rows: 24,
        xCellOffset: 10,
        yCellOffset: 5,
        zIndex: 1,
      );

      expect(chunks.length, equals(1));
      final chunk = chunks.first;
      expect(chunk.startsWith('\x1b_G'), isTrue);
      expect(chunk.endsWith('\x1b\\'), isTrue);
      expect(chunk, contains('a=T'));
      expect(chunk, contains('f=100'));
      expect(chunk, contains('i=42'));
      expect(chunk, contains('p=1'));
      expect(chunk, contains('c=80'));
      expect(chunk, contains('r=24'));
      expect(chunk, contains('X=10'));
      expect(chunk, contains('Y=5'));
      expect(chunk, contains('z=1'));
      expect(chunk, contains('m=0;'));
    });

    test('encodePngChunks splits payloads exceeding chunkSize into multiple chunks', () {
      // 5000 bytes will produce a base64 string of ~6668 characters
      final largeBytes = List<int>.generate(5000, (i) => i % 256);
      final chunks = KittyGraphics.encodePngChunks(
        imageBytes: largeBytes,
        imageId: 101,
        chunkSize: 2048,
      );

      expect(chunks.length, greaterThan(1));
      // First chunk has control metadata and m=1
      expect(chunks.first, contains('a=T,f=100,i=101,p=1,C=1,m=1;'));
      // Intermediate/last chunks do not repeat the full control data
      expect(chunks.last, contains('m=0;'));
      expect(chunks.last, isNot(contains('a=T,f=100')));
    });

    test('encodeDeleteImage formats correct deletion sequence', () {
      final seq = KittyGraphics.encodeDeleteImage(123);
      expect(seq, equals('\x1b_Ga=d,d=i,i=123\x1b\\'));
    });

    test('encodeDeleteAll formats global deletion sequence', () {
      final seq = KittyGraphics.encodeDeleteAll();
      expect(seq, equals('\x1b_Ga=d,d=a\x1b\\'));
    });

    test('displayPng wraps sequences with ANSI cursor save and restore when screen coordinates are given', () async {
      final emitted = <String>[];
      final kg = KittyGraphics(customEmitter: emitted.add);

      await kg.displayPng(
        imageBytes: [1, 2, 3],
        imageId: 42,
        columns: 50,
        screenRow: 10,
        screenCol: 25,
      );

      expect(emitted.length, equals(1));
      // Cursor save: \x1b[s
      // Cursor position: \x1b[11;26H (1-indexed)
      // Cursor restore: \x1b[u
      expect(emitted.first, startsWith('\x1b[s\x1b[11;26H\x1b_G'));
      expect(emitted.first, endsWith('\x1b\\\x1b[u'));
      expect(emitted.first, contains('c=50'));
    });

    test('displayPng and delete methods emit through customEmitter', () async {
      final emitted = <String>[];
      final kg = KittyGraphics(customEmitter: emitted.add);

      await kg.displayPng(
        imageBytes: [10, 20, 30],
        imageId: 99,
        columns: 40,
        rows: 20,
      );
      expect(emitted.length, equals(1));
      expect(emitted.first, contains('i=99'));

      await kg.deleteImage(99);
      expect(emitted.length, equals(2));
      expect(emitted.last, equals('\x1b_Ga=d,d=i,i=99\x1b\\'));

      await kg.deleteAll();
      expect(emitted.length, equals(3));
      expect(emitted.last, equals('\x1b_Ga=d,d=a\x1b\\'));
    });

    test('encodePngChunks and displayPng include source crop parameters x, y, w, h', () async {
      final emitted = <String>[];
      final kg = KittyGraphics(customEmitter: emitted.add);

      await kg.displayPng(
        imageBytes: [1, 2, 3, 4],
        imageId: 77,
        columns: 80,
        rows: 24,
        srcX: 0,
        srcY: 200,
        srcWidth: 800,
        srcHeight: 480,
      );

      expect(emitted.length, equals(1));
      expect(emitted.first, contains('x=0'));
      expect(emitted.first, contains('y=200'));
      expect(emitted.first, contains('w=800'));
      expect(emitted.first, contains('h=480'));
      expect(emitted.first, contains('c=80'));
      expect(emitted.first, contains('r=24'));
    });
  });
}
