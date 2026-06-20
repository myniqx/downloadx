import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../services/download_service.dart';
import '../util/palette.dart';
import 'download_detail_screen.dart';
import 'widgets/speed_hero.dart';
import 'widgets/transfer_card.dart';

class HomeScreen extends StatelessWidget {
  final DownloadService service;
  const HomeScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.md,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: ListenableBuilder(
                      listenable: service.ticker,
                      builder: (context, _) => SpeedHero(
                        speedBps: service.totalSpeed,
                        activeCount: service.activeCount,
                        queuedCount: 0,
                        onResumeAll: service.startAll,
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  sliver: SliverToBoxAdapter(
                    child: _TransferListHeader(
                      count: service.downloads.length,
                      onClearCompleted: _clearCompleted,
                    ),
                  ),
                ),
                if (service.downloads.isEmpty)
                  const SliverFillRemaining(child: _EmptyState())
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 100,
                    ),
                    sliver: SliverList.separated(
                      itemCount: service.downloads.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: AppSpacing.sm),
                      itemBuilder: (context, i) {
                        final vm = service.downloads[i];
                        return TransferCard(
                          vm: vm,
                          onPause: () => service.pause(vm),
                          onStart: () => service.start(vm),
                          onRemove: () => service.remove(vm),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  DownloadDetailScreen(vm: vm, service: service),
                            ),
                          ),
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
        TextButton(
          onPressed: onClearCompleted,
          child: Text(
            'Clear Completed',
            style: AppTextStyles.labelSm.copyWith(color: AppColors.primary),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

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

