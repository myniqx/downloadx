import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../models/download_vm.dart';
import '../services/download_service.dart';
import '../util/palette.dart';
import 'add_download_dialog.dart';
import 'download_detail_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

class AppShell extends StatefulWidget {
  final DownloadService service;
  const AppShell({super.key, required this.service});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  DownloadVm? _selectedDownload;
  final TextEditingController _searchCtrl = TextEditingController();

  static const _navItems = [
    _NavItem(icon: Icons.download_outlined, activeIcon: Icons.download_rounded, label: 'Home'),
    _NavItem(icon: Icons.settings_outlined, activeIcon: Icons.settings_rounded, label: 'Settings'),
  ];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _openDetail(DownloadVm vm) => setState(() => _selectedDownload = vm);
  void _closeDetail() => setState(() => _selectedDownload = null);

  Widget _buildPage(int index) {
    return switch (index) {
      0 => HomeScreen(
          service: widget.service,
          searchCtrl: _searchCtrl,
          onOpenDetail: _openDetail,
        ),
      1 => SettingsScreen(service: widget.service),
      _ => const _PlaceholderPage(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isDesktop = width >= kBreakpointMd;

    // Desktop: detail ekranı shell içinde gösterilir, sidebar sabit kalır.
    final detailVm = _selectedDownload;
    final desktopChild = detailVm != null
        ? DownloadDetailScreen(
            vm: detailVm,
            service: widget.service,
            onBack: _closeDetail,
          )
        : _buildPage(_selectedIndex);

    return isDesktop
        ? _DesktopShell(
            selectedIndex: _selectedIndex,
            navItems: _navItems,
            onDestinationSelected: (i) =>
                setState(() { _selectedIndex = i; _selectedDownload = null; }),
            service: widget.service,
            searchCtrl: _searchCtrl,
            child: desktopChild,
          )
        : _MobileShell(
            selectedIndex: _selectedIndex,
            navItems: _navItems,
            onDestinationSelected: (i) => setState(() => _selectedIndex = i),
            service: widget.service,
            child: _buildPage(_selectedIndex),
          );
  }
}

// ---------------------------------------------------------------------------
// Desktop shell — left sidebar + top header
// ---------------------------------------------------------------------------

class _DesktopShell extends StatelessWidget {
  final int selectedIndex;
  final List<_NavItem> navItems;
  final ValueChanged<int> onDestinationSelected;
  final DownloadService service;
  final TextEditingController searchCtrl;
  final Widget child;

  const _DesktopShell({
    required this.selectedIndex,
    required this.navItems,
    required this.onDestinationSelected,
    required this.service,
    required this.searchCtrl,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Row(
        children: [
          _SideNav(
            selectedIndex: selectedIndex,
            navItems: navItems,
            onDestinationSelected: onDestinationSelected,
            service: service,
          ),
          Expanded(
            child: Column(
              children: [
                _TopHeader(service: service, searchCtrl: searchCtrl),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SideNav extends StatelessWidget {
  final int selectedIndex;
  final List<_NavItem> navItems;
  final ValueChanged<int> onDestinationSelected;
  final DownloadService service;

  const _SideNav({
    required this.selectedIndex,
    required this.navItems,
    required this.onDestinationSelected,
    required this.service,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainer,
        border: Border(right: BorderSide(color: AppColors.outlineVariant)),
      ),
      child: Column(
        children: [
          const SizedBox(height: AppSpacing.lg),
          const Icon(Icons.download_rounded, size: 36, color: AppColors.primary),
          const SizedBox(height: AppSpacing.xl),
          Expanded(
            child: Column(
              children: List.generate(navItems.length, (i) {
                final item = navItems[i];
                final active = selectedIndex == i;
                return _SideNavButton(
                  icon: active ? item.activeIcon : item.icon,
                  label: item.label,
                  active: active,
                  onTap: () => onDestinationSelected(i),
                );
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.lg,
            ),
            child: Column(
              children: [
                if (kDebugMode) ...[
                  _DemoButton(service: service),
                  const SizedBox(height: AppSpacing.sm),
                ],
                _AddButton(service: service),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SideNavButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _SideNavButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.xs),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          hoverColor: AppColors.surfaceVariant.withValues(alpha: 0.5),
          child: SizedBox(
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 28,
                    color: active ? AppColors.primary : AppColors.onSurfaceVariant,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    label,
                    style: AppTextStyles.labelSm.copyWith(
                      color: active ? AppColors.primary : AppColors.onSurfaceVariant,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopHeader extends StatelessWidget {
  final DownloadService service;
  final TextEditingController searchCtrl;
  const _TopHeader({required this.service, required this.searchCtrl});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.8),
        border: const Border(bottom: BorderSide(color: AppColors.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: [
          Text('dlx', style: AppTextStyles.headlineMd.copyWith(color: AppColors.primary)),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: _SearchField(controller: searchCtrl),
            ),
          ),
          const Spacer(),
          _HeaderAction(icon: Icons.speed_outlined, tooltip: 'Speed limit'),
          const SizedBox(width: AppSpacing.xs),
          _HeaderAction(
            icon: Icons.pause_circle_outline,
            tooltip: 'Pause all',
            onPressed: service.pauseAll,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile shell — top header + bottom nav bar
// ---------------------------------------------------------------------------

class _MobileShell extends StatelessWidget {
  final int selectedIndex;
  final List<_NavItem> navItems;
  final ValueChanged<int> onDestinationSelected;
  final DownloadService service;
  final Widget child;

  const _MobileShell({
    required this.selectedIndex,
    required this.navItems,
    required this.onDestinationSelected,
    required this.service,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: _MobileHeader(service: service),
      ),
      body: child,
      bottomNavigationBar: _BottomNav(
        selectedIndex: selectedIndex,
        navItems: navItems,
        onDestinationSelected: onDestinationSelected,
      ),
    );
  }
}

class _MobileHeader extends StatelessWidget {
  final DownloadService service;
  const _MobileHeader({required this.service});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.8),
        border: const Border(bottom: BorderSide(color: AppColors.outlineVariant, width: 0.5)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Row(
            children: [
              const Icon(Icons.download_done_rounded, color: AppColors.primary),
              const SizedBox(width: AppSpacing.sm),
              Text('DownloadX',
                  style: AppTextStyles.headlineMd.copyWith(color: AppColors.primary)),
              const Spacer(),
              ListenableBuilder(
                listenable: service,
                builder: (context, _) {
                  final hasActive = service.activeCount > 0;
                  return _StartPauseAllChip(
                    hasActive: hasActive,
                    onTap: hasActive ? service.pauseAll : service.startAll,
                  );
                },
              ),
              const SizedBox(width: AppSpacing.sm),
              IconButton(
                icon: const Icon(Icons.settings_outlined, color: AppColors.onSurfaceVariant),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => SettingsScreen(service: service)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StartPauseAllChip extends StatelessWidget {
  final bool hasActive;
  final VoidCallback onTap;

  const _StartPauseAllChip({required this.hasActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(AppRadius.def),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasActive ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 16,
              color: AppColors.primary,
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              hasActive ? 'Pause All' : 'Start All',
              style: AppTextStyles.labelSm.copyWith(color: AppColors.primary),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  final int selectedIndex;
  final List<_NavItem> navItems;
  final ValueChanged<int> onDestinationSelected;

  const _BottomNav({
    required this.selectedIndex,
    required this.navItems,
    required this.onDestinationSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainer,
        border: Border(top: BorderSide(color: AppColors.outlineVariant, width: 0.5)),
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(navItems.length, (i) {
              final item = navItems[i];
              final active = selectedIndex == i;
              return _BottomNavItem(
                icon: active ? item.activeIcon : item.icon,
                label: item.label,
                active: active,
                onTap: () => onDestinationSelected(i),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _BottomNavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          color: active
              ? AppColors.secondaryContainer.withValues(alpha: 0.3)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 24,
              color: active ? AppColors.secondary : AppColors.onSurfaceVariant,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: AppTextStyles.labelSm.copyWith(
                color: active ? AppColors.secondary : AppColors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared small widgets
// ---------------------------------------------------------------------------

class _AddButton extends StatelessWidget {
  final DownloadService service;
  const _AddButton({required this.service});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primaryContainer,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => showAddDownloadDialog(context, service),
        child: const Padding(
          padding: EdgeInsets.all(AppSpacing.sm),
          child: Icon(Icons.add_rounded, color: AppColors.onPrimaryContainer, size: 24),
        ),
      ),
    );
  }
}

class _DemoButton extends StatelessWidget {
  final DownloadService service;
  const _DemoButton({required this.service});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => Tooltip(
        message: service.demoActive ? 'Clear demo' : 'Inject demo',
        child: Material(
          color: service.demoActive
              ? AppColors.primaryContainer.withValues(alpha: 0.3)
              : Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: service.toggleDemo,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Icon(
                Icons.science_outlined,
                size: 20,
                color: service.demoActive
                    ? AppColors.primary
                    : AppColors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  const _SearchField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: AppTextStyles.bodyMd.copyWith(color: AppColors.onSurface),
      decoration: InputDecoration(
        hintText: 'Search downloads...',
        hintStyle: AppTextStyles.bodyMd.copyWith(color: AppColors.onSurfaceVariant),
        prefixIcon: const Icon(Icons.search, color: AppColors.onSurfaceVariant, size: 20),
        contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.full),
          borderSide: const BorderSide(color: AppColors.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.full),
          borderSide: const BorderSide(color: AppColors.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.full),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
        filled: true,
        fillColor: AppColors.surfaceContainerLow,
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _HeaderAction({required this.icon, required this.tooltip, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 22),
      tooltip: tooltip,
      color: AppColors.onSurfaceVariant,
      onPressed: onPressed ?? () {},
      style: IconButton.styleFrom(
        shape: const CircleBorder(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Placeholder pages
// ---------------------------------------------------------------------------

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('Coming soon', style: TextStyle(color: AppColors.onSurfaceVariant)),
    );
  }
}

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _NavItem({required this.icon, required this.activeIcon, required this.label});
}
