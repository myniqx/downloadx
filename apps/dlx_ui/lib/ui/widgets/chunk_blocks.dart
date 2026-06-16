import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../../util/palette.dart';

/// Renders the file as a single horizontal track, each chunk a region scaled to
/// its byte range, filled proportionally to how much of it is downloaded and
/// tinted by chunk health (good / poor / stalled, green when complete). This is
/// the graphical analogue of an IDM segment bar.
class ChunkBlocks extends StatelessWidget {
  final int? totalBytes;
  final List<ChunkSnapshot> chunks;
  final double height;

  const ChunkBlocks({
    super.key,
    required this.totalBytes,
    required this.chunks,
    this.height = 44,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _ChunkBlocksPainter(
          totalBytes: totalBytes,
          chunks: chunks,
          trackColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderColor: Theme.of(context).dividerColor,
        ),
      ),
    );
  }
}

class _ChunkBlocksPainter extends CustomPainter {
  final int? totalBytes;
  final List<ChunkSnapshot> chunks;
  final Color trackColor;
  final Color borderColor;

  _ChunkBlocksPainter({
    required this.totalBytes,
    required this.chunks,
    required this.trackColor,
    required this.borderColor,
  });

  static const double _radius = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(_radius));
    canvas.drawRRect(rrect, Paint()..color = trackColor);

    final total = totalBytes;
    if (total == null || total <= 0) {
      // Unknown size: a diagonal hatch conveys "streaming, length unknown".
      _hatch(canvas, size);
      _border(canvas, rrect);
      return;
    }

    canvas.save();
    canvas.clipRRect(rrect);
    for (final c in chunks) {
      final xs = (c.offset / total) * w;
      final cw = (c.length / total) * w;
      if (cw <= 0) continue;
      final completed = c.status == ChunkStatus.completed;
      final fillFrac = c.length > 0 ? (c.downloadedBytes / c.length).clamp(0.0, 1.0) : 0.0;
      // Downloaded portion of the chunk.
      final color = colorForQuality(c.quality, completed: completed);
      canvas.drawRect(
        Rect.fromLTWH(xs, 0, cw * fillFrac, h),
        Paint()..color = color,
      );
      // Remaining portion: a faint tint of the same color.
      if (fillFrac < 1) {
        canvas.drawRect(
          Rect.fromLTWH(xs + cw * fillFrac, 0, cw * (1 - fillFrac), h),
          Paint()..color = color.withValues(alpha: 0.18),
        );
      }
      // Chunk boundary.
      canvas.drawLine(
        Offset(xs, 0),
        Offset(xs, h),
        Paint()
          ..color = borderColor
          ..strokeWidth = 1,
      );
    }
    canvas.restore();
    _border(canvas, rrect);
  }

  void _hatch(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF4FC3F7).withValues(alpha: 0.35)
      ..strokeWidth = 6;
    for (var x = -size.height; x < size.width; x += 16) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  void _border(Canvas canvas, RRect rrect) {
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _ChunkBlocksPainter old) => true;
}
