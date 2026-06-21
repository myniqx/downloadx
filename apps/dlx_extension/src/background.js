"use strict";

import { registerRequestWatcher, getCapturedForTab, clearCapturedForTab, updateFileExtensions } from './request-watcher.js';
import { startWsClient, isConnected, sendWs, addWsListener } from './ws-client.js';

startWsClient();

addWsListener(({ type, msg }) => {
  if (type === 'connect' || type === 'disconnect') {
    updateAllBadges();
    chrome.runtime.sendMessage({ action: 'ws-status', connected: type === 'connect' }).catch(() => {});
  }

  if (type === 'message') {
    switch (msg.type) {
      case 'handshake':
      case 'options':
        applyOptions(msg.options ?? msg);
        break;
      case 'progress':
        chrome.runtime.sendMessage({ action: 'progress', downloads: msg.downloads }).catch(() => {});
        break;
    }
  }
});

function applyOptions(options) {
  if (Array.isArray(options.fileExtensions)) {
    updateFileExtensions(options.fileExtensions);
    chrome.storage.session.set({ fileExtensions: options.fileExtensions });
  }
  if (typeof options.browseMonitor === 'boolean') {
    chrome.storage.session.set({ browseMonitor: options.browseMonitor });
  }
}

// ---- Badge ------------------------------------------------------------------

function updateBadge(tabId) {
  const count = getCapturedForTab(tabId).length;
  chrome.action.setBadgeText({ text: count > 0 ? String(count) : '', tabId });
  chrome.action.setBadgeBackgroundColor({ color: '#4d8eff', tabId });
}

function updateAllBadges() {
  chrome.tabs.query({}, (tabs) => tabs.forEach(t => updateBadge(t.id)));
}

chrome.tabs.onActivated.addListener(({ tabId }) => updateBadge(tabId));

registerRequestWatcher((item) => updateBadge(item.tabId));

// ---- Messages from popup ----------------------------------------------------

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.action === 'get-status') {
    sendResponse({ connected: isConnected() });
    return;
  }

  if (msg.action === 'get-captured') {
    chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
      sendResponse({ items: tab ? getCapturedForTab(tab.id) : [] });
    });
    return true;
  }

  if (msg.action === 'scan-tab') {
    chrome.storage.session.get(['fileExtensions', 'browseMonitor'], (stored) => {
      const browseMonitor = stored.browseMonitor !== false;
      if (!browseMonitor) { sendResponse({ links: [] }); return; }

      const exts = stored.fileExtensions ?? null;
      chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
        if (!tab?.id) { sendResponse({ links: [] }); return; }
        chrome.scripting.executeScript(
          { target: { tabId: tab.id }, func: scanPageLinks, args: [exts] },
          (results) => sendResponse({ links: results?.[0]?.result ?? [] }),
        );
      });
    });
    return true;
  }

  if (msg.action === 'add-url') {
    if (!isConnected()) { sendResponse({ ok: false, error: 'dlx is not running' }); return; }
    sendWs({ action: 'add-url', url: msg.url, filename: msg.filename ?? undefined });
    sendResponse({ ok: true });
    return;
  }

  if (msg.action === 'clear-captured') {
    chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
      if (tab) { clearCapturedForTab(tab.id); updateBadge(tab.id); }
      sendResponse({ ok: true });
    });
    return true;
  }
});

// Injected into page context — no extension APIs.
function scanPageLinks(fileExtensions) {
  const extSet = fileExtensions
    ? new Set(fileExtensions.map(e => e.toLowerCase()))
    : new Set(['zip','gz','tar','rar','7z','iso','dmg','pkg','exe','msi','deb','rpm','apk','mp4','mkv','avi','mov','webm','mp3','flac','aac','wav','pdf','epub','torrent']);

  const extRe = new RegExp('\\.(' + [...extSet].join('|') + ')(\\?.*)?$', 'i');
  const seen = new Set();
  const links = [];
  document.querySelectorAll('a[href]').forEach(a => {
    const href = a.href;
    if (!href || seen.has(href) || !extRe.test(href)) return;
    seen.add(href);
    links.push({
      url: href,
      filename: a.textContent.trim() || href.split('/').pop().split('?')[0] || href,
      size: null,
    });
  });
  return links;
}
