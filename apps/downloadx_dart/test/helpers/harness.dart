import 'package:downloadx/downloadx.dart';

import 'mock_io.dart';

/// Fresh in-memory IO + fast-retry config per test, mirroring the TS
/// `makeHarness()`. Small chunk sizes / retry delays surface behaviour quickly.
class Harness {
  final MockIo io;
  late final DownloadX manager;

  Harness._(this.io);

  static Future<Harness> create({
    int maxParallel = 3,
    int targetChunkCount = 4,
    int minChunkSize = 64,
    int maxRetries = 3,
    int retryDelay = 1,
    int requestTimeout = 5000,
    bool journal = false,
    int speedLimit = 0,
    MockIo? io,
  }) async {
    final h = Harness._(io ?? MockIo());
    h.manager = await createDownloadX(DownloadXConfig(
      io: h.io,
      targetPath: '/downloads',
      cachePath: '/cache',
      maxParallel: maxParallel,
      targetChunkCount: targetChunkCount,
      minChunkSize: minChunkSize,
      maxRetries: maxRetries,
      retryDelay: retryDelay,
      retryBackoff: 1,
      requestTimeout: requestTimeout,
      journal: journal,
      speedLimit: speedLimit,
      speedSampleWindow: 500,
    ));
    return h;
  }
}
