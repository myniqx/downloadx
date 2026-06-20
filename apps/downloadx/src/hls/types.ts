export interface HlsStream {
  bandwidth: number;
  resolution: string | null;
  codecs: string | null;
  uri: string;
}

export interface HlsMasterPlaylist {
  /** Sorted by bandwidth descending — [0] is the best quality. */
  streams: HlsStream[];
}

export interface HlsSegment {
  uri: string;
  durationSec: number;
  byteRange: { offset: number; length: number } | null;
}

export interface HlsMediaPlaylist {
  segments: HlsSegment[];
  totalDurationSec: number;
  targetDuration: number;
  /** True when #EXT-X-ENDLIST is absent — live stream, not supported. */
  isLive: boolean;
}
