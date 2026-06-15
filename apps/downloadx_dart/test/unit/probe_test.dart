import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

void main() {
  group('filenameFromUrl', () {
    test('extracts last path segment, url-decoded', () {
      expect(filenameFromUrl('https://example.com/path/My%20File.iso'),
          'My File.iso');
    });

    test('returns null when no segment', () {
      expect(filenameFromUrl('https://example.com/'), isNull);
    });
  });

  group('filenameFromDisposition', () {
    test('plain filename', () {
      expect(filenameFromDisposition('attachment; filename="report.pdf"'),
          'report.pdf');
    });

    test('unquoted filename', () {
      expect(filenameFromDisposition('attachment; filename=report.pdf'),
          'report.pdf');
    });

    test('RFC 5987 filename* takes precedence and is decoded', () {
      expect(
        filenameFromDisposition(
            "attachment; filename=\"fallback.pdf\"; filename*=UTF-8''na%C3%AFve.pdf"),
        'naïve.pdf',
      );
    });

    test('returns null for absent filename', () {
      expect(filenameFromDisposition('inline'), isNull);
      expect(filenameFromDisposition(null), isNull);
    });
  });
}
