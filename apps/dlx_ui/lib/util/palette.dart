import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// AppColors — design.md "Velocity Dark" token map
// ---------------------------------------------------------------------------

abstract final class AppColors {
  // surfaces
  static const surface               = Color(0xFF0B1326);
  static const surfaceDim            = Color(0xFF0B1326);
  static const surfaceBright         = Color(0xFF31394D);
  static const surfaceContainerLowest = Color(0xFF060E20);
  static const surfaceContainerLow   = Color(0xFF131B2E);
  static const surfaceContainer      = Color(0xFF171F33);
  static const surfaceContainerHigh  = Color(0xFF222A3D);
  static const surfaceContainerHighest = Color(0xFF2D3449);
  static const surfaceVariant        = Color(0xFF2D3449);

  // on-surface
  static const onSurface             = Color(0xFFDAE2FD);
  static const onSurfaceVariant      = Color(0xFFC2C6D6);
  static const inverseSurface        = Color(0xFFDAE2FD);
  static const inverseOnSurface      = Color(0xFF283044);

  // outlines
  static const outline               = Color(0xFF8C909F);
  static const outlineVariant        = Color(0xFF424754);

  // primary (electric blue)
  static const primary               = Color(0xFFADC6FF);
  static const onPrimary             = Color(0xFF002E6A);
  static const primaryContainer      = Color(0xFF4D8EFF);
  static const onPrimaryContainer    = Color(0xFF00285D);
  static const inversePrimary        = Color(0xFF005AC2);
  static const surfaceTint           = Color(0xFFADC6FF);
  static const primaryFixed          = Color(0xFFD8E2FF);
  static const primaryFixedDim       = Color(0xFFADC6FF);
  static const onPrimaryFixed        = Color(0xFF001A42);
  static const onPrimaryFixedVariant = Color(0xFF004395);

  // secondary (emerald — completed / healthy)
  static const secondary             = Color(0xFF4EDEA3);
  static const onSecondary           = Color(0xFF003824);
  static const secondaryContainer    = Color(0xFF00A572);
  static const onSecondaryContainer  = Color(0xFF00311F);
  static const secondaryFixed        = Color(0xFF6FFBBE);
  static const secondaryFixedDim     = Color(0xFF4EDEA3);
  static const onSecondaryFixed      = Color(0xFF002113);
  static const onSecondaryFixedVariant = Color(0xFF005236);

  // tertiary (amber — paused / warning)
  static const tertiary              = Color(0xFFFFB95F);
  static const onTertiary            = Color(0xFF472A00);
  static const tertiaryContainer     = Color(0xFFCA8100);
  static const onTertiaryContainer   = Color(0xFF3E2400);
  static const tertiaryFixed         = Color(0xFFFFDDB8);
  static const tertiaryFixedDim      = Color(0xFFFFB95F);
  static const onTertiaryFixed       = Color(0xFF2A1700);
  static const onTertiaryFixedVariant = Color(0xFF653E00);

  // error
  static const error                 = Color(0xFFFFB4AB);
  static const onError               = Color(0xFF690005);
  static const errorContainer        = Color(0xFF93000A);
  static const onErrorContainer      = Color(0xFFFFDAD6);

  // background (alias of surface)
  static const background            = Color(0xFF0B1326);
  static const onBackground          = Color(0xFFDAE2FD);

  // semantic shortcuts (used by state/chunk color helpers below)
  static const stateDownloading      = primary;         // electric blue
  static const stateCompleted        = secondary;       // emerald
  static const statePaused           = tertiary;        // amber
  static const stateError            = error;           // red
  static const stateIdle             = Color(0xFF8C909F); // outline
  static const stateCancelled        = Color(0xFF8C909F);
  static const stateProbing          = Color(0xFF90CAF9);
}

// ---------------------------------------------------------------------------
// AppSpacing — design.md spacing tokens
// ---------------------------------------------------------------------------

abstract final class AppSpacing {
  static const double xs     = 4;
  static const double sm     = 12;
  static const double base   = 8;
  static const double md     = 16;
  static const double lg     = 24;
  static const double xl     = 32;
  static const double gutter = 16;
  static const double marginMobile  = 16;
  static const double marginDesktop = 32;
}

// ---------------------------------------------------------------------------
// AppRadius — design.md rounded tokens
// ---------------------------------------------------------------------------

abstract final class AppRadius {
  static const double sm   = 4;
  static const double def  = 8;
  static const double md   = 12;
  static const double lg   = 16;
  static const double xl   = 24;
  static const double full = 9999;
}

// ---------------------------------------------------------------------------
// AppTextStyles — design.md typography tokens
// ---------------------------------------------------------------------------

abstract final class AppTextStyles {
  static const headlineLg = TextStyle(
    fontFamily: 'Inter', fontSize: 32, fontWeight: FontWeight.w700,
    height: 40 / 32, letterSpacing: -0.02 * 32,
  );
  static const headlineLgMobile = TextStyle(
    fontFamily: 'Inter', fontSize: 24, fontWeight: FontWeight.w700,
    height: 32 / 24,
  );
  static const headlineMd = TextStyle(
    fontFamily: 'Inter', fontSize: 20, fontWeight: FontWeight.w600,
    height: 28 / 20,
  );
  static const bodyLg = TextStyle(
    fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.w400,
    height: 24 / 16,
  );
  static const bodyMd = TextStyle(
    fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.w400,
    height: 20 / 14,
  );
  static const dataDisplay = TextStyle(
    fontFamily: 'Geist', fontSize: 14, fontWeight: FontWeight.w600,
    height: 16 / 14, letterSpacing: 0.02 * 14,
  );
  static const labelSm = TextStyle(
    fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.w500,
    height: 16 / 12,
  );
}

// ---------------------------------------------------------------------------
// AppTheme — MaterialApp'e verilecek ThemeData
// ---------------------------------------------------------------------------

abstract final class AppTheme {
  static ThemeData get dark => ThemeData(
    useMaterial3: true,
    colorScheme: const ColorScheme(
      brightness: Brightness.dark,
      primary:               AppColors.primary,
      onPrimary:             AppColors.onPrimary,
      primaryContainer:      AppColors.primaryContainer,
      onPrimaryContainer:    AppColors.onPrimaryContainer,
      inversePrimary:        AppColors.inversePrimary,
      secondary:             AppColors.secondary,
      onSecondary:           AppColors.onSecondary,
      secondaryContainer:    AppColors.secondaryContainer,
      onSecondaryContainer:  AppColors.onSecondaryContainer,
      tertiary:              AppColors.tertiary,
      onTertiary:            AppColors.onTertiary,
      tertiaryContainer:     AppColors.tertiaryContainer,
      onTertiaryContainer:   AppColors.onTertiaryContainer,
      error:                 AppColors.error,
      onError:               AppColors.onError,
      errorContainer:        AppColors.errorContainer,
      onErrorContainer:      AppColors.onErrorContainer,
      surface:               AppColors.surface,
      onSurface:             AppColors.onSurface,
      onSurfaceVariant:      AppColors.onSurfaceVariant,
      outline:               AppColors.outline,
      outlineVariant:        AppColors.outlineVariant,
      inverseSurface:        AppColors.inverseSurface,
      onInverseSurface:      AppColors.inverseOnSurface,
      surfaceTint:           AppColors.surfaceTint,
      surfaceContainerHighest: AppColors.surfaceContainerHighest,
      surfaceContainerHigh:  AppColors.surfaceContainerHigh,
      surfaceContainer:      AppColors.surfaceContainer,
      surfaceContainerLow:   AppColors.surfaceContainerLow,
      surfaceContainerLowest: AppColors.surfaceContainerLowest,
      surfaceDim:            AppColors.surfaceDim,
      surfaceBright:         AppColors.surfaceBright,
    ),
    scaffoldBackgroundColor: AppColors.background,
    cardTheme: CardThemeData(
      color: AppColors.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: const BorderSide(color: AppColors.outlineVariant),
      ),
      margin: EdgeInsets.zero,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.surfaceContainerLowest,
      foregroundColor: AppColors.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: const BorderSide(color: AppColors.outlineVariant),
      ),
      elevation: 8,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceContainerLowest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.def),
        borderSide: const BorderSide(color: AppColors.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.def),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.def),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.def),
        ),
      ),
    ),
    textTheme: const TextTheme(
      displayLarge:  AppTextStyles.headlineLg,
      titleLarge:    AppTextStyles.headlineMd,
      titleMedium:   AppTextStyles.bodyLg,
      bodyLarge:     AppTextStyles.bodyLg,
      bodyMedium:    AppTextStyles.bodyMd,
      bodySmall:     AppTextStyles.labelSm,
      labelSmall:    AppTextStyles.labelSm,
    ),
  );
}

// ---------------------------------------------------------------------------
// Chunk & state color helpers — design.md semantic color map
// ---------------------------------------------------------------------------

/// Stable, deterministic colors for chart series (chunks / downloads).
const List<Color> seriesColors = [
  AppColors.primary,
  AppColors.secondary,
  AppColors.tertiary,
  Color(0xFFBA68C8),
  Color(0xFF4DD0E1),
  Color(0xFFE57373),
  Color(0xFFAED581),
  Color(0xFF7986CB),
  Color(0xFFFFD54F),
  Color(0xFF4DB6AC),
];

Color colorForIndex(int i) => seriesColors[i % seriesColors.length];

Color colorForQuality(ChunkQuality q, {bool completed = false}) {
  if (completed) return AppColors.stateCompleted;
  return switch (q) {
    ChunkQuality.good    => AppColors.stateDownloading,
    ChunkQuality.poor    => AppColors.statePaused,
    ChunkQuality.stalled => AppColors.stateError,
  };
}

Color colorForState(DownloadState s) => switch (s) {
  DownloadState.completed   => AppColors.stateCompleted,
  DownloadState.downloading => AppColors.stateDownloading,
  DownloadState.probing     => AppColors.stateProbing,
  DownloadState.paused      => AppColors.statePaused,
  DownloadState.error       => AppColors.stateError,
  DownloadState.cancelled   => AppColors.stateCancelled,
  DownloadState.idle        => AppColors.stateIdle,
};

IconData iconForState(DownloadState s) => switch (s) {
  DownloadState.completed   => Icons.check_circle,
  DownloadState.downloading => Icons.downloading,
  DownloadState.probing     => Icons.search,
  DownloadState.paused      => Icons.pause_circle,
  DownloadState.error       => Icons.error,
  DownloadState.cancelled   => Icons.cancel,
  DownloadState.idle        => Icons.schedule,
};
