import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

/// Stable, deterministic colors for chart series (chunks / downloads). The same
/// index always maps to the same hue so a chunk keeps its color across frames.
const List<Color> seriesColors = [
  Color(0xFF4FC3F7),
  Color(0xFF81C784),
  Color(0xFFFFB74D),
  Color(0xFFBA68C8),
  Color(0xFF4DD0E1),
  Color(0xFFE57373),
  Color(0xFFAED581),
  Color(0xFF7986CB),
  Color(0xFFFFD54F),
  Color(0xFF4DB6AC),
];

Color colorForIndex(int i) => seriesColors[i % seriesColors.length];

/// Color a chunk by its health, used in the block view.
Color colorForQuality(ChunkQuality q, {bool completed = false}) {
  if (completed) return const Color(0xFF66BB6A);
  return switch (q) {
    ChunkQuality.good => const Color(0xFF4FC3F7),
    ChunkQuality.poor => const Color(0xFFFFB74D),
    ChunkQuality.stalled => const Color(0xFFE57373),
  };
}

Color colorForState(DownloadState s) => switch (s) {
      DownloadState.completed => const Color(0xFF66BB6A),
      DownloadState.downloading => const Color(0xFF4FC3F7),
      DownloadState.probing => const Color(0xFF4DD0E1),
      DownloadState.paused => const Color(0xFFFFB74D),
      DownloadState.error => const Color(0xFFE57373),
      DownloadState.cancelled => const Color(0xFF9E9E9E),
      DownloadState.idle => const Color(0xFF9E9E9E),
    };

IconData iconForState(DownloadState s) => switch (s) {
      DownloadState.completed => Icons.check_circle,
      DownloadState.downloading => Icons.downloading,
      DownloadState.probing => Icons.search,
      DownloadState.paused => Icons.pause_circle,
      DownloadState.error => Icons.error,
      DownloadState.cancelled => Icons.cancel,
      DownloadState.idle => Icons.schedule,
    };
