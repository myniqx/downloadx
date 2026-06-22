/// Human-readable formatting shared across the UI.
library;

String formatBytes(num n) {
  final b = n.toDouble();
  if (b >= 1e9) return '${(b / 1e9).toStringAsFixed(2)} GB';
  if (b >= 1e6) return '${(b / 1e6).toStringAsFixed(1)} MB';
  if (b >= 1e3) return '${(b / 1e3).toStringAsFixed(1)} KB';
  return '${b.round()} B';
}

String formatSpeed(num bytesPerSec) => '${formatBytes(bytesPerSec)}/s';

String formatDuration(int ms) {
  if (ms <= 0) return '0s';
  final secs = (ms / 1000).round();
  if (secs < 60) return '${secs}s';
  final mins = secs ~/ 60;
  if (mins < 60) return '${mins}m ${secs % 60}s';
  final hours = mins ~/ 60;
  if (hours < 24) return '${hours}h ${mins % 60}m';
  return '${hours ~/ 24}d ${hours % 24}h';
}

String formatPercent(double? percent) =>
    percent == null ? '—' : '${percent.toStringAsFixed(1)}%';

/// Format bytes/sec back into a compact string suitable for the speed-limit field.
String formatSpeedLimit(int bytesPerSec) {
  if (bytesPerSec == 0) return '0';
  if (bytesPerSec % (1024 * 1024 * 1024) == 0) return '${bytesPerSec ~/ (1024 * 1024 * 1024)}G';
  if (bytesPerSec % (1024 * 1024) == 0) return '${bytesPerSec ~/ (1024 * 1024)}M';
  if (bytesPerSec % 1024 == 0) return '${bytesPerSec ~/ 1024}k';
  return '$bytesPerSec';
}

/// Parse a speed-limit string like "2", "2M", "500k", "1.5g" into bytes/sec.
/// Returns null on empty, 0 for an explicit 0 (= unlimited).
int? parseSpeedLimit(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) return null;
  final m = RegExp(r'^(\d+(?:\.\d+)?)\s*([kmg]?)b?(?:/s)?$').firstMatch(s);
  if (m == null) return null;
  final value = double.parse(m.group(1)!);
  final unit = m.group(2);
  final mult = switch (unit) {
    'k' => 1024,
    'm' => 1024 * 1024,
    'g' => 1024 * 1024 * 1024,
    _ => 1,
  };
  return (value * mult).round();
}
