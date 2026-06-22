import path from 'node:path';
import type { DlxContext } from '../types.js';
import { parsePlaylist } from './parser.js';
import type { HlsMediaPlaylist, HlsStream } from './types.js';

/** Resolved media playlist — segments ready to be planned as chunks. */
export interface HlsMediaResolution {
  type: 'media';
  playlist: HlsMediaPlaylist;
}

/** Returned when a master playlist has multiple streams — caller should present
 *  the list to the user; no segments are downloaded in this case. */
export interface HlsMultiStreamResult {
  type: 'multi-stream';
  streams: HlsStream[];
}

export type HlsResolution = HlsMediaResolution | HlsMultiStreamResult;

/**
 * HLS playlist resolver + segment concatenator. Downloading is no longer the
 * session's job — each segment is downloaded as an `isSegment` Chunk by the
 * owning Download. The session only:
 *   - resolves a playlist URL into a media playlist or a multi-stream list,
 *   - registers child downloads for multi-stream master playlists,
 *   - concatenates downloaded segment files into the final output,
 *   - cleans up segment files.
 */
export class HlsSession {
  constructor(
    private readonly id: string,
    private readonly context: DlxContext,
  ) {}

  // ---- playlist resolution -------------------------------------------------

  /** Fetch and parse the playlist at `url`.
   *  - media playlist → { type: 'media', playlist }
   *  - master with >1 stream → { type: 'multi-stream', streams }
   *  - master with 1 stream → resolves that stream's media playlist
   *  Throws on live streams (no #EXT-X-ENDLIST). */
  async resolve(url: string): Promise<HlsResolution> {
    const text = await this.fetchText(url);
    const result = parsePlaylist(text, url);

    if (result.type === 'media') {
      if (result.playlist.isLive) {
        throw new Error('Live HLS streams are not supported');
      }
      return { type: 'media', playlist: result.playlist };
    }

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
    if (mediaResult.playlist.isLive) {
      throw new Error('Live HLS streams are not supported');
    }
    return { type: 'media', playlist: mediaResult.playlist };
  }

  /** Register each stream of a multi-stream master as a separate idle download. */
  async registerStreams(
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

  /** Directory where this download's segment files live. */
  segDir(): string {
    return this.context.io.joinPath(this.context.cachePath, `${this.id}-hls`);
  }

  /** Local file path for segment `index`. */
  segPath(index: number): string {
    return this.context.io.joinPath(this.segDir(), `seg-${String(index).padStart(6, '0')}.ts`);
  }

  // ---- concat --------------------------------------------------------------

  /** Concatenate ordered segment files into `output`. Uses io.concatSegments
   *  (e.g. ffmpeg) when available, otherwise a binary append fallback. */
  async concat(segments: string[], output: string): Promise<void> {
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
