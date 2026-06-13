export type DownloadStatus = 'queued' | 'downloading' | 'paused' | 'completed' | 'failed' | 'cancelled';

export interface DownloadEntry {
  id: string;
  url: string;
  filename: string | null;
  targetPath: string | null;
  cachePath: string;
  speedLimit: number | null;
  status: DownloadStatus;
  addedAt: number;
  completedAt: number | null;
  totalBytes: number | null;
  downloadedBytes: number;
  errorMessage: string | null;
}

export interface DaemonConfig {
  maxParallel: number;
  speedLimit: number;
  targetPath: string;
  cachePath: string;
}

// Requests

export interface AddRequest      { cmd: 'add';      url: string; targetPath?: string; speedLimit?: number }
export interface PauseRequest    { cmd: 'pause';    id: string }
export interface ResumeRequest   { cmd: 'resume';   id: string }
export interface CancelRequest   { cmd: 'cancel';   id: string }
export interface ClearRequest    { cmd: 'clear';    id: string }
export interface ListRequest     { cmd: 'list' }
export interface StatusRequest   { cmd: 'status';   id: string }
export interface WatchRequest    { cmd: 'watch' }
export interface ShutdownRequest { cmd: 'shutdown' }
export interface SetRequest      { cmd: 'set';      key?: string; value?: string; id?: string }
export interface GetRequest      { cmd: 'get';      key?: string }

export type IpcRequest =
  | AddRequest | PauseRequest | ResumeRequest
  | CancelRequest | ClearRequest | ListRequest | StatusRequest
  | WatchRequest | ShutdownRequest | SetRequest | GetRequest;

// Responses

export interface OkResponse<T = unknown>    { ok: true;  data: T }
export interface ErrorResponse              { ok: false; error: string }
export type IpcResponse<T = unknown> = OkResponse<T> | ErrorResponse;

// Events (pushed to watch subscribers)

export interface ProgressEvent {
  event: 'progress';
  id: string;
  downloadedBytes: number;
  totalBytes: number | null;
  totalSpeed: number;
  activeChunks: number;
  percent: number | null;
}

export interface ChunkProgressEvent {
  event: 'chunkProgress';
  id: string;
  chunkId: string;
  offset: number;
  length: number;
  downloadedBytes: number;
  instantSpeed: number;
  windowedSpeed: number;
  quality: 'good' | 'poor' | 'stalled';
}

export interface StateChangeEvent {
  event: 'stateChange';
  id: string;
  previous: DownloadStatus;
  current: DownloadStatus;
}

export interface CompletedEvent {
  event: 'completed';
  id: string;
  filename: string;
  totalBytes: number;
  durationMs: number;
}

export interface ErrorEvent {
  event: 'error';
  id: string;
  chunkId: string | null;
  message: string;
  fatal: boolean;
}

export interface DiagnosticEvent {
  event: 'diagnostic';
  id: string;
  chunkId: string | null;
  level: 'info' | 'warn' | 'error';
  code: string;
  message: string;
  timestamp: number;
}

export type IpcEvent =
  | ProgressEvent | ChunkProgressEvent | StateChangeEvent
  | CompletedEvent | ErrorEvent | DiagnosticEvent;

// Wire format: every line on the socket is one of these
export type IpcMessage = IpcRequest | IpcResponse | IpcEvent;
