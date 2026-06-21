import { withRetry, HttpStatusError } from '../retry.js';
import { Throttle } from '../throttle.js';
import type { GlobalConfig, FetchInit } from '../types.js';
import { parsePlaylist, selectBestStream } from './parser.js';
import type { HlsMediaPlaylist, HlsSegment } from './types.js';

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

const MAX_PARALLEL_SEGMENTS = 4;

export class HlsSession {
  constructor(
    private readonly id: string,
    private readonly global: GlobalConfig,
    private readonly throttle: Throttle,
    private readonly callbacks: HlsSessionCallbacks,
  ) {}

  async run(masterUrl: string, outputPath: string): Promise<HlsSessionResult> {
    const playlist = await this.resolveMediaPlaylist(masterUrl);

    if (playlist.isLive) {
      throw new Error('Live HLS streams are not supported');
    }

    const segDir = this.global.io.joinPath(this.global.cachePath, `${this.id}-hls`);
    await this.global.io.mkdir(segDir);

    const segmentPaths = await this.downloadSegments(playlist, segDir);
    await this.concatSegments(segmentPaths, outputPath);
    return { segmentPaths, playlist, outputPath };
  }

  // ---- playlist resolution -------------------------------------------------

  private async resolveMediaPlaylist(url: string): Promise<HlsMediaPlaylist> {
    const text = await this.fetchText(url);
    const result = parsePlaylist(text, url);

    if (result.type === 'media') return result.playlist;

    const best = selectBestStream(result.playlist);
    if (!best) throw new Error('HLS master playlist has no streams');

    const mediaText = await this.fetchText(best.uri);
    const mediaResult = parsePlaylist(mediaText, best.uri);
    if (mediaResult.type !== 'media') {
      throw new Error('Expected media playlist, got another master playlist');
    }
    return mediaResult.playlist;
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
    const path = this.global.io.joinPath(segDir, `seg-${String(index).padStart(6, '0')}.ts`);

    await withRetry(
      async () => {
        const init: FetchInit = {};
        if (seg.byteRange) {
          const end = seg.byteRange.offset + seg.byteRange.length - 1;
          init.headers = { Range: `bytes=${seg.byteRange.offset}-${end}` };
        }

        const res = await this.global.io.fetch(seg.uri, init);
        if (!res.ok) throw new HttpStatusError(res.status, res.statusText ?? '');

        const buf = await res.arrayBuffer();

        await this.throttle.consume(buf.byteLength);

        await this.global.io.writeFile(path, new Uint8Array(buf));
      },
      {
        maxRetries: this.global.maxRetries,
        retryDelay: this.global.retryDelay,
        retryBackoff: this.global.retryBackoff,
      },
    );

    return path;
  }

  // ---- concat --------------------------------------------------------------

  private async concatSegments(segments: string[], output: string): Promise<void> {
    const io = this.global.io;
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
    const res = await this.global.io.fetch(url, {
      headers: { Accept: 'application/vnd.apple.mpegurl, application/x-mpegurl, */*' },
    });
    if (!res.ok) throw new Error(`Failed to fetch playlist: HTTP ${res.status} ${url}`);
    return res.text();
  }

  /** Delete all segment files on cancel/error cleanup. */
  async cleanup(segDir: string): Promise<void> {
    try {
      const io = this.global.io;
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
