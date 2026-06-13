import type {
  DownloadProgressPayload,
  ChunkProgressPayload,
  ChunkLifecyclePayload,
  DownloadStatePayload,
  DownloadCompletedPayload,
  DownloadErrorPayload,
  DiagnosticPayload,
} from '@downloadx/core';

import type { DownloadState } from '@downloadx/core';

export type DownloadStatus = DownloadState | 'queued' | 'failed';

export interface DownloadEntry {
  id: string;
  url: string;
  filename: string | null;
  targetPath: string | null;
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
  targetChunkCount: number;
  minChunkSize: number;
  journal: boolean;
}

// Requests

export interface AddRequest      { cmd: 'add';      url: string; targetPath?: string; speedLimit?: number }
export interface PauseRequest    { cmd: 'pause';    id: string }
export interface ResumeRequest   { cmd: 'resume';   id: string }
export interface RestartRequest  { cmd: 'restart';  id: string }
export interface CancelRequest   { cmd: 'cancel';   id: string }
export interface ClearRequest    { cmd: 'clear';    id: string }
export interface ListRequest     { cmd: 'list' }
export interface StatusRequest   { cmd: 'status';   id: string }
export interface WatchRequest    { cmd: 'watch' }
export interface ShutdownRequest { cmd: 'shutdown' }
export interface SetRequest      { cmd: 'set';      key?: string | undefined; value?: string | undefined; id?: string | undefined }
export interface GetRequest      { cmd: 'get';      key?: string | undefined; id?: string | undefined }

export type IpcRequest =
  | AddRequest | PauseRequest | ResumeRequest | RestartRequest
  | CancelRequest | ClearRequest | ListRequest | StatusRequest
  | WatchRequest | ShutdownRequest | SetRequest | GetRequest;

// Responses

export interface OkResponse<T = unknown>    { ok: true;  data: T }
export interface ErrorResponse              { ok: false; error: string }
export type IpcResponse<T = unknown> = OkResponse<T> | ErrorResponse;

// Events (pushed to watch subscribers)

export interface ProgressEvent extends DownloadProgressPayload {
  event: 'progress';
}

export interface ChunkProgressEvent extends ChunkProgressPayload {
  event: 'chunkProgress';
}

export interface ChunkLifecycleEvent extends ChunkLifecyclePayload {
  event: 'chunkLifecycle';
}

export interface StateChangeEvent extends DownloadStatePayload {
  event: 'stateChange';
}

export interface CompletedEvent extends DownloadCompletedPayload {
  event: 'completed';
}

export interface ErrorEvent extends Omit<DownloadErrorPayload, 'error'> {
  event: 'error';
  message: string;
}

export interface DiagnosticEvent extends DiagnosticPayload {
  event: 'diagnostic';
}

export type IpcEvent =
  | ProgressEvent | ChunkProgressEvent | ChunkLifecycleEvent | StateChangeEvent
  | CompletedEvent | ErrorEvent | DiagnosticEvent;

// Wire format: every line on the socket is one of these
export type IpcMessage = IpcRequest | IpcResponse | IpcEvent;
