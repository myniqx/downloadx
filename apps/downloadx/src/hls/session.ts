import path from 'node:path';
import { withRetry, HttpStatusError } from '../retry.js';
import { Throttle } from '../throttle.js';
import type { DlxContext, FetchInit } from '../types.js';
import { parsePlaylist } from './parser.js';
import type { HlsMediaPlaylist, HlsSegment, HlsStream } from './types.js';

export interface HlsSessionCallbacks {
  onProgress(downloadedSegments: number, totalSegments: number): void;
  onError(msg: string): void;
  isCancelled(): boolean;
  isPaused(): boolean;
}

export interface HlsSessionResult {
  /** Ordered list of local segment file paths ready to be concatenated. */
  segmentPaths: string[];
  playlist: HlsMediaPlaylist;
  /** Final concatenated output file path. */
  outputPath: string;
}

/** Returned when a master playlist has multiple streams — caller should present
 *  the list to the user; no segments are downloaded in this case. */
export interface HlsMultiStreamResult {
  type: 'multi-stream';
  streams: HlsStream[];
}

const MAX_PARALLEL_SEGMENTS = 4;

export class HlsSession {
  constructor(
    private readonly id: string,
    private readonly context: DlxContext,
    private readonly throttle: Throttle,
    private readonly callbacks: HlsSessionCallbacks,
  ) {}

  /** Run the HLS session.
   *  - Single stream → downloads segments and returns HlsSessionResult.
   *  - Multiple streams → registers each as a separate idle Download via
   *    context.addUrl() and returns HlsMultiStreamResult. */
  async run(
    masterUrl: string,
    outputPath: string,
    baseFilename: string,
  ): Promise<HlsSessionResult | HlsMultiStreamResult> {
    const resolution = await this.resolvePlaylist(masterUrl);

    if (resolution.type === 'multi-stream') {
      await this.registerStreams(resolution.streams, baseFilename, outputPath);
      return resolution;
    }

    const playlist = resolution.playlist;
    if (playlist.isLive) {
      throw new Error('Live HLS streams are not supported');
    }

    const segDir = this.context.io.joinPath(this.context.cachePath, `${this.id}-hls`);
    await this.context.io.mkdir(segDir);

    const segmentPaths = await this.downloadSegments(playlist, segDir);
    await this.concatSegments(segmentPaths, outputPath);
    return { segmentPaths, playlist, outputPath };
  }

  // ---- playlist resolution -------------------------------------------------

  private async resolvePlaylist(
    url: string,
  ): Promise<{ type: 'media'; playlist: HlsMediaPlaylist } | HlsMultiStreamResult> {
    const text = await this.fetchText(url);
    const result = parsePlaylist(text, url);

    if (result.type === 'media') return { type: 'media', playlist: result.playlist };

    const streams = result.playlist.streams;
    if (streams.length === 0) throw new Error('HLS master playlist has no streams');

    if (streams.length > 1) {
      return { type: 'multi-stream', streams };
    }

    // Single stream — resolve directly.
    const mediaText = await this.fetchText(streams[0]!.uri);
    const mediaResult = parsePlaylist(mediaText, streams[0]!.uri);
    if (mediaResult.type !== 'media') {
      throw new Error('Expected media playlist, got another master playlist');
    }
    return { type: 'media', playlist: mediaResult.playlist };
  }

  private async registerStreams(
    streams: HlsStream[],
    baseFilename: string,
    outputPath: string,
  ): Promise<void> {
    const ext = path.extname(baseFilename) || '.ts';
    const stem = path.basename(baseFilename, ext);
    const dir = path.dirname(outputPath);

    for (let i = 0; i < streams.length; i++) {
      const stream = streams[i]!;
      const qualifier =
        stream.resolution ??
        (stream.bandwidth ? `${Math.round(stream.bandwidth / 1000)}kbps` : null) ??
        `stream-${i + 1}`;
      const filename = `${stem} ${qualifier}${ext}`;
      await this.context.addUrl(stream.uri, {
        filename,
        targetPath: dir,
        autoStart: false,
      });
    }
  }

  // ---- segment download ----------------------------------------------------

  private async downloadSegments(
    playlist: HlsMediaPlaylist,
    segDir: string,
  ): Promise<string[]> {
    const segments = playlist.segments;
    const total = segments.length;
    const paths: string[] = [];
    let completedCount = 0;

    // Process in windows of MAX_PARALLEL_SEGMENTS.
    for (let i = 0; i < total; i += MAX_PARALLEL_SEGMENTS) {
      if (this.callbacks.isCancelled()) throw new Error('cancelled');

      // Pause: spin-wait until unpaused or cancelled.
      while (this.callbacks.isPaused()) {
        if (this.callbacks.isCancelled()) throw new Error('cancelled');
        await sleep(200);
      }

      const batch = segments.slice(i, i + MAX_PARALLEL_SEGMENTS);
      const batchPaths = await Promise.all(
        batch.map((seg, batchIdx) =>
          this.downloadSegment(seg, i + batchIdx, segDir),
        ),
      );

      paths.push(...batchPaths);

      completedCount += batch.length;
      this.callbacks.onProgress(completedCount, total);
    }

    return paths;
  }

  private async downloadSegment(
    seg: HlsSegment,
    index: number,
    segDir: string,
  ): Promise<string> {
    const path = this.context.io.joinPath(segDir, `seg-${String(index).padStart(6, '0')}.ts`);

    await withRetry(
      async () => {
        const init: FetchInit = {};
        if (seg.byteRange) {
          const end = seg.byteRange.offset + seg.byteRange.length - 1;
          init.headers = { Range: `bytes=${seg.byteRange.offset}-${end}` };
        }

        const res = await this.context.io.fetch(seg.uri, init);
        if (!res.ok) throw new HttpStatusError(res.status, res.statusText ?? '');

        const buf = await res.arrayBuffer();

        await this.throttle.consume(buf.byteLength);

        await this.context.io.writeFile(path, new Uint8Array(buf));
      },
      {
        maxRetries: this.context.maxRetries,
        retryDelay: this.context.retryDelay,
        retryBackoff: this.context.retryBackoff,
      },
    );

    return path;
  }

  // ---- concat --------------------------------------------------------------

  private async concatSegments(segments: string[], output: string): Promise<void> {
    const io = this.context.io;
    if (io.concatSegments) {
      await io.concatSegments(segments, output);
      return;
    }
    // Binary concat fallback: read each segment and append to output.
    const parts: Uint8Array[] = [];
    for (const seg of segments) {
      parts.push(await io.readFile(seg));
    }
    const total = parts.reduce((acc, p) => acc + p.byteLength, 0);
    const merged = new Uint8Array(total);
    let offset = 0;
    for (const part of parts) {
      merged.set(part, offset);
      offset += part.byteLength;
    }
    await io.writeFile(output, merged);
  }

  // ---- helpers -------------------------------------------------------------

  private async fetchText(url: string): Promise<string> {
    const res = await this.context.io.fetch(url, {
      headers: { Accept: 'application/vnd.apple.mpegurl, application/x-mpegurl, */*' },
    });
    if (!res.ok) throw new Error(`Failed to fetch playlist: HTTP ${res.status} ${url}`);
    return res.text();
  }

  /** Delete all segment files on cancel/error cleanup. */
  async cleanup(segDir: string): Promise<void> {
    try {
      const io = this.context.io;
      // Best-effort: unlink known paths, ignore errors.
      for (let i = 0; ; i++) {
        const p = io.joinPath(segDir, `seg-${String(i).padStart(6, '0')}.ts`);
        if (!(await io.exists(p))) break;
        await io.unlink(p).catch(() => undefined);
      }
    } catch {
      // ignore
    }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
