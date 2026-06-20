---
name: Velocity Dark
colors:
  surface: '#0b1326'
  surface-dim: '#0b1326'
  surface-bright: '#31394d'
  surface-container-lowest: '#060e20'
  surface-container-low: '#131b2e'
  surface-container: '#171f33'
  surface-container-high: '#222a3d'
  surface-container-highest: '#2d3449'
  on-surface: '#dae2fd'
  on-surface-variant: '#c2c6d6'
  inverse-surface: '#dae2fd'
  inverse-on-surface: '#283044'
  outline: '#8c909f'
  outline-variant: '#424754'
  surface-tint: '#adc6ff'
  primary: '#adc6ff'
  on-primary: '#002e6a'
  primary-container: '#4d8eff'
  on-primary-container: '#00285d'
  inverse-primary: '#005ac2'
  secondary: '#4edea3'
  on-secondary: '#003824'
  secondary-container: '#00a572'
  on-secondary-container: '#00311f'
  tertiary: '#ffb95f'
  on-tertiary: '#472a00'
  tertiary-container: '#ca8100'
  on-tertiary-container: '#3e2400'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#d8e2ff'
  primary-fixed-dim: '#adc6ff'
  on-primary-fixed: '#001a42'
  on-primary-fixed-variant: '#004395'
  secondary-fixed: '#6ffbbe'
  secondary-fixed-dim: '#4edea3'
  on-secondary-fixed: '#002113'
  on-secondary-fixed-variant: '#005236'
  tertiary-fixed: '#ffddb8'
  tertiary-fixed-dim: '#ffb95f'
  on-tertiary-fixed: '#2a1700'
  on-tertiary-fixed-variant: '#653e00'
  background: '#0b1326'
  on-background: '#dae2fd'
  surface-variant: '#2d3449'
typography:
  headline-lg:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 40px
    letterSpacing: -0.02em
  headline-lg-mobile:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '700'
    lineHeight: 32px
  headline-md:
    fontFamily: Inter
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 28px
  body-lg:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  body-md:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  data-display:
    fontFamily: Geist
    fontSize: 14px
    fontWeight: '600'
    lineHeight: 16px
    letterSpacing: 0.02em
  label-sm:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '500'
    lineHeight: 16px
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  base: 8px
  xs: 4px
  sm: 12px
  md: 16px
  lg: 24px
  xl: 32px
  gutter: 16px
  margin-mobile: 16px
  margin-desktop: 32px
---

## Brand & Style

This design system is engineered for high-performance utility, blending the structural reliability of Material Design 3 with a sophisticated, tech-forward aesthetic. The personality is efficient, precise, and powerful, aimed at power users who value data density and system transparency.

The visual style utilizes **Modern Minimalism** with **Glassmorphism** accents. The interface prioritizes clear information hierarchy through high-contrast typography and vibrant functional color signaling. Elements appear as layered instrumentation, using subtle translucency and background blurs to maintain context while highlighting active processes.

## Colors

The palette is anchored in a deep, nocturnal foundation to reduce eye strain during long sessions.

- **Primary (Electric Blue):** Used for active states, primary actions, and ongoing download progress.
- **Success (Emerald):** Reserved exclusively for completed tasks and healthy connection statuses.
- **Warning (Amber):** Identifies paused downloads, throttled speeds, or disk space alerts.
- **Surface Strategy:** The background uses Deep Slate (#0F172A). UI containers and cards use Navy Charcoal (#1E293B) to create a clear "object-based" hierarchy.
- **Typography:** Titles and critical data points use Pure White. Metadata and secondary labels use Slate-300 to maintain a clear visual dip between primary and secondary information.

## Typography

The system uses **Inter** for its exceptional legibility in UI contexts and **Geist** for technical data points (speed, ETA, file sizes) to provide a monospaced, "engineered" feel to the metrics.

- **Headlines:** Bold and tight-tracked to feel impactful and modern.
- **Body:** Standardized on a 14px/20px grid for optimal reading of file paths and descriptions.
- **Data Points:** Use `data-display` for metrics like "MB/s" or "Time Remaining" to distinguish dynamic values from static labels.

## Layout & Spacing

The layout follows a **Fluid Grid** system based on an 8px square rhythm.

- **Desktop:** 12-column grid with 24px gutters. Content cards should typically span 4 columns (for grid view) or 12 columns (for list view).
- **Mobile:** 4-column grid with 16px margins.
- **Alignment:** All technical data must be right-aligned in list views to allow for easy comparison of download speeds and percentages across multiple items.

## Elevation & Depth

This system utilizes **Tonal Layering** combined with **Glassmorphism** for its elevation model.

- **Level 0 (Background):** Deep Slate (#0F172A), solid.
- **Level 1 (Cards/Containers):** Navy Charcoal (#1E293B) at 80% opacity with a 16px Backdrop Blur.
- **Level 2 (Overlays/Menus):** Navy Charcoal at 90% opacity with a subtle 1px border (#334155) and an ambient shadow (0px 8px 24px rgba(0,0,0,0.5)).
- **Interactions:** Hovering over a card should increase the border-opacity and slightly brighten the background color to signify focus.

## Shapes

The design system uses a generous **Rounded** (16px/1rem) corner radius to soften the technical nature of the application and align with Flutter's Material 3 philosophy.

- **Standard Elements:** Buttons and input fields use 8px (rounded-md).
- **Primary Containers:** Download cards and modal dialogs use 16px (rounded-lg).
- **Progress Bars:** Fully rounded (pill-shaped) to allow for smooth animation of the segmented indicators.

## Components

### Buttons

- **Primary:** Electric Blue fill with White text. High-contrast, 8px corner radius.
- **Secondary:** Ghost style with a Slate-700 border and Slate-300 text.
- **Icon Buttons:** Circular background with 20px Feather-style icons (1.5px stroke weight).

### Progress Bars

- **Style:** Segmented appearance. The background track is Deep Slate (#0F172A). The active fill is Electric Blue (#3B82F6).
- **Animation:** Use a subtle "pulse" or "glow" on the leading edge of the progress bar during active data transfer.

### Cards

- **Download Item:** Glassmorphic card with a 1px stroke (#334155). Contains file name (Headline-md), progress bar, speed (Data-display), and action icons (Pause/Cancel).

### Chips

- **Status Chips:** Small, semi-transparent backgrounds with status-colored text (e.g., Emerald text on a 10% opacity Emerald background) for labels like "4K Video" or "Direct Link."

### Input Fields

- Dark-filled (#0F172A) with a 1px border that glows Electric Blue when focused. All inputs should use monospaced text for URL entry.

---

## Flutter Implementation

**Source file:** `apps/dlx_ui/lib/util/palette.dart`

All design tokens are implemented in four `abstract final class` definitions. Import with:

```dart
import 'package:dlx_ui/util/palette.dart';
```

---

### Colors → `AppColors`

Every color token from this document maps to a `static const Color` on `AppColors`.

| Design token             | Dart constant                        |
|--------------------------|--------------------------------------|
| `surface`                | `AppColors.surface`                  |
| `surface-container-low`  | `AppColors.surfaceContainerLow`      |
| `surface-container-high` | `AppColors.surfaceContainerHigh`     |
| `on-surface`             | `AppColors.onSurface`                |
| `outline-variant`        | `AppColors.outlineVariant`           |
| `primary` (electric blue)| `AppColors.primary`                  |
| `secondary` (emerald)    | `AppColors.secondary`                |
| `tertiary` (amber)       | `AppColors.tertiary`                 |
| `error`                  | `AppColors.error`                    |

**Semantic shortcuts** (use these in widgets, not raw hex):

| Semantic use         | Dart constant                  |
|----------------------|--------------------------------|
| Active / downloading | `AppColors.stateDownloading`   |
| Completed            | `AppColors.stateCompleted`     |
| Paused / warning     | `AppColors.statePaused`        |
| Error                | `AppColors.stateError`         |
| Idle / cancelled     | `AppColors.stateIdle`          |

`Theme.of(context).colorScheme` is pre-wired to these same values via `AppTheme.dark`. Prefer `colorScheme` for standard M3 roles (e.g. `colorScheme.surface`); use `AppColors.*` directly only for tokens M3 does not cover.

---

### Spacing → `AppSpacing`

8px base grid. Use these constants instead of raw numbers.

| Token            | Value | Dart constant           |
|------------------|-------|-------------------------|
| `xs`             | 4px   | `AppSpacing.xs`         |
| `base`           | 8px   | `AppSpacing.base`       |
| `sm`             | 12px  | `AppSpacing.sm`         |
| `md`             | 16px  | `AppSpacing.md`         |
| `lg`             | 24px  | `AppSpacing.lg`         |
| `xl`             | 32px  | `AppSpacing.xl`         |
| `gutter`         | 16px  | `AppSpacing.gutter`     |
| `margin-mobile`  | 16px  | `AppSpacing.marginMobile`  |
| `margin-desktop` | 32px  | `AppSpacing.marginDesktop` |

```dart
Padding(padding: EdgeInsets.all(AppSpacing.md), child: ...)
SizedBox(height: AppSpacing.lg)
```

---

### Border Radius → `AppRadius`

| Token     | Value  | Dart constant    | Usage                            |
|-----------|--------|------------------|----------------------------------|
| `sm`      | 4px    | `AppRadius.sm`   | Progress bars (pill look)        |
| `DEFAULT` | 8px    | `AppRadius.def`  | Buttons, input fields            |
| `md`      | 12px   | `AppRadius.md`   | Chips, small cards               |
| `lg`      | 16px   | `AppRadius.lg`   | Download cards, dialogs          |
| `xl`      | 24px   | `AppRadius.xl`   | Bottom sheets, large overlays    |
| `full`    | 9999px | `AppRadius.full` | Avatar / icon containers         |

```dart
BorderRadius.circular(AppRadius.lg)  // card
BorderRadius.circular(AppRadius.def) // button / input
BorderRadius.circular(AppRadius.full) // progress bar pill
```

---

### Typography → `AppTextStyles`

| Design token       | Dart constant                  | Use for                              |
|--------------------|--------------------------------|--------------------------------------|
| `headline-lg`      | `AppTextStyles.headlineLg`     | Screen titles (desktop)              |
| `headline-lg-mobile`| `AppTextStyles.headlineLgMobile`| Screen titles (mobile)              |
| `headline-md`      | `AppTextStyles.headlineMd`     | Card titles, file names              |
| `body-lg`          | `AppTextStyles.bodyLg`         | Primary body, descriptions           |
| `body-md`          | `AppTextStyles.bodyMd`         | Secondary body, file paths           |
| `data-display`     | `AppTextStyles.dataDisplay`    | Speed, ETA, file size (Geist, mono)  |
| `label-sm`         | `AppTextStyles.labelSm`        | Metadata labels, status chips        |

`data-display` uses **Geist** (monospaced feel). All dynamic numeric values (MB/s, %, ETA) should use this style.

These are also wired into `Theme.of(context).textTheme`:
- `titleLarge` → `headlineMd`
- `bodyMedium` → `bodyMd`
- `bodySmall` → `labelSm`

```dart
Text('4.2 MB/s', style: AppTextStyles.dataDisplay)
Text('filename.iso', style: AppTextStyles.headlineMd)
Text('Target folder', style: AppTextStyles.labelSm.copyWith(color: AppColors.onSurfaceVariant))
```

---

### Theme → `AppTheme.dark`

Applied once in `main.dart`:

```dart
MaterialApp(theme: AppTheme.dark, ...)
```

Pre-configured defaults (no need to set manually in widgets):

| Widget            | Pre-configured style                                    |
|-------------------|---------------------------------------------------------|
| `Card`            | `surfaceContainerLow` bg, `outlineVariant` 1px border, `AppRadius.lg` |
| `AppBar`          | `surfaceContainerLowest` bg, no elevation               |
| `AlertDialog`     | `surfaceContainerLow` bg, `outlineVariant` border, `AppRadius.lg` |
| `TextField`       | `surfaceContainerLowest` fill, blue glow on focus       |
| `FilledButton`    | `primary` bg, `onPrimary` text, `AppRadius.def`         |
| `TextButton`      | `primary` text, `AppRadius.def`                         |

---

### State & Chunk Color Helpers

These functions live in `palette.dart` and map engine enums to design tokens:

```dart
colorForState(DownloadState s) → Color   // use in tile icons, progress bars
colorForQuality(ChunkQuality q, {bool completed}) → Color  // use in chunk blocks / chart series
colorForIndex(int i) → Color             // stable chart series color by index
iconForState(DownloadState s) → IconData // matching icon for each state
```

---

### Glassmorphism Card Pattern

For Level 1 elevation (download cards, overlays):

```dart
Container(
  decoration: BoxDecoration(
    color: AppColors.surfaceContainerLow.withValues(alpha: 0.8),
    borderRadius: BorderRadius.circular(AppRadius.lg),
    border: Border.all(color: AppColors.outlineVariant),
  ),
  child: BackdropFilter(
    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
    child: ...,
  ),
)
```
