"use strict";

let MEDIA_EXTS = new Set([
  'mp4','mkv','avi','mov','webm','flv','wmv','m4v','ts','m3u8',
  'mp3','flac','aac','wav','ogg','opus','m4a',
]);

let FILE_EXTS = new Set([
  'zip','gz','tar','rar','7z','bz2','xz','zst',
  'iso','dmg','img','pkg','exe','msi','deb','rpm','apk',
  'pdf','epub','mobi','djvu',
  'torrent',
]);

export function updateFileExtensions(exts) {
  const all = new Set(exts.map(e => e.toLowerCase()));
  const mediaExts = new Set(['mp4','mkv','avi','mov','webm','flv','wmv','m4v','ts','m3u8','mp3','flac','aac','wav','ogg','opus','m4a']);
  MEDIA_EXTS = new Set([...all].filter(e => mediaExts.has(e)));
  FILE_EXTS  = new Set([...all].filter(e => !mediaExts.has(e)));
}

const MEDIA_TYPES = [
  'video/', 'audio/', 'application/octet-stream',
  'application/zip', 'application/x-rar', 'application/x-7z',
  'application/pdf', 'application/x-bittorrent',
];

// tabId → Map<url, item>
const captured = new Map();
// requestId → {url, tabId, requestHeaders}
const pending = new Map();

function extOf(url) {
  try {
    const path = new URL(url).pathname;
    const dot = path.lastIndexOf('.');
    return dot >= 0 ? path.slice(dot + 1).toLowerCase() : '';
  } catch { return ''; }
}

// HLS segment pattern: seg-1-v1-a1.ts, 00001.ts, chunk-0001.ts etc.
const HLS_SEGMENT = /\/(seg-\d|chunk-\d|\d{3,})\b.*\.ts(\?|$)/i;
// HLS sub-playlist: index-v1-a1.m3u8, chunklist_b800000.m3u8 etc. (keep master.m3u8)
const HLS_SUBLIST = /\/(index-|chunklist|media_\d)/i;

function isHlsSegment(url) {
  return HLS_SEGMENT.test(url);
}

function isHlsSubPlaylist(url) {
  if (extOf(url) !== 'm3u8') return false;
  return HLS_SUBLIST.test(url);
}

function isDownloadable(url, responseHeaders) {
  if (isHlsSegment(url) || isHlsSubPlaylist(url)) return false;

  const ext = extOf(url);
  if (MEDIA_EXTS.has(ext) || FILE_EXTS.has(ext)) return true;

  for (const h of responseHeaders) {
    const name = h.name.toLowerCase();
    const val  = h.value || '';
    if (name === 'content-type') {
      if (MEDIA_TYPES.some(t => val.startsWith(t))) return true;
    }
    if (name === 'content-disposition' && val.toLowerCase().includes('attachment')) {
      return true;
    }
  }
  return false;
}

function filenameFrom(url, responseHeaders) {
  for (const h of responseHeaders) {
    if (h.name.toLowerCase() === 'content-disposition') {
      const m = h.value.match(/filename\*?=(?:UTF-8'')?["']?([^"';\r\n]+)/i);
      if (m) return decodeURIComponent(m[1].trim());
    }
  }
  try {
    const p = new URL(url).pathname;
    const name = p.split('/').pop();
    return name ? decodeURIComponent(name) : url;
  } catch { return url; }
}

function sizeFrom(responseHeaders) {
  for (const h of responseHeaders) {
    if (h.name.toLowerCase() === 'content-length') {
      const n = parseInt(h.value, 10);
      return isNaN(n) ? null : n;
    }
  }
  return null;
}

export function registerRequestWatcher(onCaptured) {
  chrome.webRequest.onSendHeaders.addListener(
    (info) => {
      if (info.method !== 'GET') return;
      pending.set(info.requestId, {
        url: info.url,
        tabId: info.tabId,
        requestHeaders: info.requestHeaders || [],
      });
    },
    { urls: ['http://*/*', 'https://*/*'] },
    ['extraHeaders', 'requestHeaders'],
  );

  chrome.webRequest.onHeadersReceived.addListener(
    (res) => {
      const req = pending.get(res.requestId);
      if (!req) return;
      pending.delete(res.requestId);

      if (!isDownloadable(res.url, res.responseHeaders || [])) return;

      const tabId = req.tabId;
      if (tabId < 0) return; // background request, skip

      if (!captured.has(tabId)) captured.set(tabId, new Map());
      const tabMap = captured.get(tabId);
      if (tabMap.has(res.url)) return; // already captured

      const filenameFromHeaders = filenameFrom(res.url, res.responseHeaders || []);
      const item = {
        url: res.url,
        filename: filenameFromHeaders,
        size: sizeFrom(res.responseHeaders || []),
        mime: (res.responseHeaders || []).find(h => h.name.toLowerCase() === 'content-type')?.value ?? null,
        tabId,
        isHls: extOf(res.url) === 'm3u8',
      };
      tabMap.set(res.url, item);

      chrome.tabs.get(tabId, (tab) => {
        if (!chrome.runtime.lastError && tab?.title) {
          item.pageTitle = tab.title;
        }
        onCaptured(item);
      });
    },
    { urls: ['http://*/*', 'https://*/*'] },
    ['extraHeaders', 'responseHeaders'],
  );

  chrome.webRequest.onErrorOccurred.addListener(
    (info) => pending.delete(info.requestId),
    { urls: ['http://*/*', 'https://*/*'] },
  );

  // Clean up captured list when tab closes.
  chrome.tabs.onRemoved.addListener((tabId) => captured.delete(tabId));
}

export function getCapturedForTab(tabId) {
  return [...(captured.get(tabId)?.values() ?? [])];
}

export function clearCapturedForTab(tabId) {
  captured.delete(tabId);
}
