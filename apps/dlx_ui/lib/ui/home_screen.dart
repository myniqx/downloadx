import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../models/download_vm.dart';
import '../services/download_service.dart';
import '../util/palette.dart';
import 'download_detail_screen.dart';
import 'widgets/dlx_button.dart';
import 'widgets/speed_hero.dart';
import 'widgets/transfer_card.dart';

class HomeScreen extends StatelessWidget {
  final DownloadService service;
  final TextEditingController searchCtrl;
  final ValueChanged<DownloadVm>? onOpenDetail;

  const HomeScreen({
    super.key,
    required this.service,
    required this.searchCtrl,
    this.onOpenDetail,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([service, searchCtrl]),
      builder: (context, _) {
        final query = searchCtrl.text.trim().toLowerCase();
        final downloads = query.isEmpty
            ? service.downloads
            : service.downloads.where((vm) {
                final name = (vm.desc.filename ?? vm.desc.url).toLowerCase();
                return name.contains(query);
              }).toList();

        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.md,
              ),
              sliver: SliverToBoxAdapter(
                child: ListenableBuilder(
                  listenable: service.ticker,
                  builder: (context, _) {
                    final order = service.downloads.map((vm) => vm.id).toList();
                    final colorIndex = {
                      for (var i = 0; i < order.length; i++) order[i]: i,
                    };
                    final hasPaused = service.downloads.any((vm) =>
                        vm.download.state == DownloadState.paused ||
                        vm.download.state == DownloadState.idle ||
                        vm.download.state == DownloadState.error);
                    return SpeedHero(
                      speedBps: service.totalSpeed,
                      activeCount: service.activeCount,
                      history: service.globalSpeedHistory,
                      seriesOrder: order,
                      colorOf: (id) => colorForIndex(colorIndex[id] ?? 0),
                      queuedCount: 0,
                      onResumeAll: hasPaused ? service.startAll : null,
                    );
                  },
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              sliver: SliverToBoxAdapter(
                child: _TransferListHeader(
                  count: downloads.length,
                  onClearCompleted: _clearCompleted,
                ),
              ),
            ),
            if (downloads.isEmpty)
              SliverFillRemaining(
                child: query.isNotEmpty
                    ? _NoResultsState(query: query)
                    : const _EmptyState(),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 100,
                ),
                sliver: SliverList.separated(
                  itemCount: downloads.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, i) {
                    final vm = downloads[i];
                    return TransferCard(
                      vm: vm,
                      onPause: () => service.pause(vm),
                      onStart: () => service.start(vm),
                      onRemove: () => service.remove(vm),
                      onTap: () {
                        if (onOpenDetail != null) {
                          onOpenDetail!(vm);
                        } else {
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) =>
                                DownloadDetailScreen(vm: vm, service: service),
                          ));
                        }
                      },
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  void _clearCompleted() {
    final completed = service.downloads
        .where((vm) => vm.download.state == DownloadState.completed)
        .toList();
    for (final vm in completed) {
      service.remove(vm);
    }
  }
}

// ---------------------------------------------------------------------------
// Transfer list header
// ---------------------------------------------------------------------------

class _TransferListHeader extends StatelessWidget {
  final int count;
  final VoidCallback onClearCompleted;

  const _TransferListHeader({required this.count, required this.onClearCompleted});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('Active Transfers', style: AppTextStyles.headlineMd.copyWith(color: AppColors.onSurface)),
        const SizedBox(width: AppSpacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          child: Text(
            '$count Items',
            style: AppTextStyles.labelSm.copyWith(color: AppColors.onSurfaceVariant),
          ),
        ),
        const Spacer(),
        DlxButton(
          label: 'Clear Completed',
          onPressed: onClearCompleted,
          variant: DlxButtonVariant.ghost,
          size: DlxButtonSize.sm,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _NoResultsState extends StatelessWidget {
  final String query;
  const _NoResultsState({required this.query});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, size: 64,
              color: AppColors.onSurfaceVariant.withValues(alpha: 0.5)),
          const SizedBox(height: AppSpacing.md),
          Text('No results for "$query"',
              style: AppTextStyles.bodyLg.copyWith(color: AppColors.onSurface)),
          const SizedBox(height: AppSpacing.xs),
          Text('Try a different filename or URL',
              style: AppTextStyles.bodyMd.copyWith(color: AppColors.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_download_outlined, size: 64, color: AppColors.onSurfaceVariant.withValues(alpha: 0.5)),
          const SizedBox(height: AppSpacing.md),
          Text('No downloads yet',
              style: AppTextStyles.bodyLg.copyWith(color: AppColors.onSurface)),
          const SizedBox(height: AppSpacing.xs),
          Text('Tap + to start one',
              style: AppTextStyles.bodyMd.copyWith(color: AppColors.onSurfaceVariant)),
        ],
      ),
    );
  }
}

