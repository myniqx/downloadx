import 'package:downloadx/downloadx.dart';

/// Minimal end-to-end example. The default [NativeIo] talks to real disk and
/// the network, so nothing has to be wired up.
Future<void> main(List<String> args) async {
  final url =
      args.isNotEmpty ? args.first : 'https://speed.hetzner.de/100MB.bin';

  final manager = await createDownloadX(DownloadXConfig(
    targetPath: './downloads',
    maxParallel: 3,
    targetChunkCount: 4,
    journal: true,
  ));

  final dl = await manager.addUrl(url);

  dl.emitter.onType<ProgressEvent>((p) {
    final pct = p.percent?.toStringAsFixed(1) ?? '?';
    final mbps = (p.totalSpeed / 1e6).toStringAsFixed(2);
    final eta = p.etaMs == null ? '?' : '${(p.etaMs! / 1000).round()}s';
    // ignore: avoid_print
    print('$pct% @ $mbps MB/s, ETA $eta');
  });

  dl.emitter.onType<CompletedEvent>((c) {
    // ignore: avoid_print
    print('done: ${c.filename} (${c.totalBytes} bytes in ${c.durationMs}ms)');
  });

  await dl.start();
}
