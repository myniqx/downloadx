// Pure-Dart tests for the UI's formatting helpers. The app itself needs
// platform plugins (path_provider) to start, so it isn't booted here.
import 'package:dlx_ui/util/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatBytes', () {
    test('scales units', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1500), '1.5 KB');
      expect(formatBytes(2 * 1000 * 1000), '2.0 MB');
      expect(formatBytes(3 * 1000 * 1000 * 1000), '3.00 GB');
    });
  });

  group('parseSpeedLimit', () {
    test('parses units and empty', () {
      expect(parseSpeedLimit(''), isNull);
      expect(parseSpeedLimit('2M'), 2 * 1024 * 1024);
      expect(parseSpeedLimit('500k'), 500 * 1024);
      expect(parseSpeedLimit('1.5g'), (1.5 * 1024 * 1024 * 1024).round());
      expect(parseSpeedLimit('100'), 100);
      expect(parseSpeedLimit('garbage'), isNull);
    });
  });

  group('formatDuration', () {
    test('formats ranges', () {
      expect(formatDuration(5000), '5s');
      expect(formatDuration(90000), '1m 30s');
      expect(formatDuration(3700000), '1h 1m');
    });
  });
}
