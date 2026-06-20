/// downloadx — an IDM-style download manager for Dart and Flutter.
///
/// Parallel chunked downloads with random-access disk writes, dynamic chunk
/// splitting, resume across restarts, misbehaving-server recovery, network
/// idle timeouts, stall auto-recovery, speed limiting, retries with backoff,
/// an NDJSON diagnostic journal, and compact `describe()` reports.
///
/// The default [NativeIo] talks to real disk and the network via `dart:io`, so
/// a Flutter or Dart consumer never has to wire anything up:
///
/// ```dart
/// final manager = await createDownloadX(DownloadXConfig(
///   targetPath: '/path/to/downloads',
///   maxParallel: 3,
///   targetChunkCount: 4,
///   journal: true,
/// ));
/// final dl = await manager.addUrl('https://example.com/big.iso');
/// dl.emitter.onType<ProgressEvent>((p) {
///   print('${p.percent?.toStringAsFixed(1)}%');
/// });
/// await dl.start();
/// ```
library;

export 'src/chunk.dart' show Chunk, ChunkParams;
export 'src/chunk_scheduler.dart'
    show
        planChunks,
        findSplitCandidate,
        ChunkPlan,
        PlanOptions,
        SplitCandidate,
        FindSplitOptions;
export 'src/config.dart' show DownloadConfig, GlobalConfig;
export 'src/constants.dart'
    show
        appName,
        metaExt,
        tempExt,
        journalExt,
        metaSchemaVersion,
        unknownSizeLength,
        DefaultConfig;
export 'src/download.dart' show Download;
export 'src/download_x.dart' show DownloadX, createDownloadX;
export 'src/events.dart';
export 'src/io.dart'
    show
        DownloadxIo,
        FetchInit,
        FetchResponse,
        FetchHeaders,
        MapFetchHeaders,
        CancelToken,
        AbortError,
        TransientAbort;
export 'src/io_fetch.dart' show FetchFn;
export 'src/meta.dart'
    show
        MetaLocator,
        metaPath,
        createEmptyMeta,
        createMeta,
        applyProbeToMeta,
        loadMeta,
        listMetaFiles,
        persistMeta,
        deleteMeta,
        canResumeAgainst,
        dehydrateState;
export 'src/native_io.dart' show NativeIo;
export 'src/probe.dart'
    show probeUrl, ProbeOptions, filenameFromDisposition, filenameFromUrl;
export 'src/retry.dart'
    show
        withRetry,
        RetryOptions,
        RetryInfo,
        HttpStatusError,
        RangeNotHonoredError;
export 'src/speed_tracker.dart' show SpeedTracker, AggregateSpeed;
export 'src/throttle.dart' show Throttle;
export 'src/types.dart';
export 'src/hls/types.dart';
export 'src/hls/parser.dart'
    show
        parseMasterPlaylist,
        parseMediaPlaylist,
        parsePlaylist,
        selectBestStream,
        HlsMasterResult,
        HlsMediaResult,
        HlsParseResult;
