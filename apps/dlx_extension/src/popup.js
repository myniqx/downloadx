"use strict";

const STATES = ['state-scanning', 'state-empty', 'state-list', 'state-error', 'state-offline'];

function show(id) {
  STATES.forEach(s => document.getElementById(s).classList.toggle('hidden', s !== id));
}

function formatSize(bytes) {
  if (!bytes) return '';
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 ** 2) return (bytes / 1024).toFixed(1) + ' KB';
  if (bytes < 1024 ** 3) return (bytes / 1024 ** 2).toFixed(1) + ' MB';
  return (bytes / 1024 ** 3).toFixed(2) + ' GB';
}

// ---- Offline state ----------------------------------------------------------

const RETRY_INTERVAL_MS = 5000;
let retryTimer = null;
let retryRemaining = 0;

function showOffline() {
  updateConnBadge(false);
  show('state-offline');
  startRetryCountdown();
}

function startRetryCountdown() {
  clearInterval(retryTimer);
  retryRemaining = Math.round(RETRY_INTERVAL_MS / 1000);
  updateCountdown();
  retryTimer = setInterval(() => {
    retryRemaining--;
    updateCountdown();
    if (retryRemaining <= 0) {
      clearInterval(retryTimer);
      checkConnection();
    }
  }, 1000);
}

function updateCountdown() {
  const el = document.getElementById('retry-countdown');
  if (el) el.textContent = retryRemaining > 0 ? `Retrying in ${retryRemaining}s…` : '';
}

document.getElementById('btn-retry').addEventListener('click', () => {
  clearInterval(retryTimer);
  updateCountdown();
  checkConnection();
});

// ---- Connection check -------------------------------------------------------

function updateConnBadge(connected) {
  const badge = document.getElementById('conn-badge');
  badge.title = connected ? 'dlx is running' : 'dlx is not running';
  badge.classList.toggle('connected', connected);
}

function checkConnection() {
  chrome.runtime.sendMessage({ action: 'get-status' }, (res) => {
    if (res?.connected) {
      updateConnBadge(true);
      loadItems();
    } else {
      showOffline();
    }
  });
}

// ---- Progress updates -------------------------------------------------------

chrome.runtime.onMessage.addListener((msg) => {
  if (msg.action === 'ws-status') {
    if (msg.connected) {
      clearInterval(retryTimer);
      updateConnBadge(true);
      loadItems();
    } else {
      showOffline();
    }
  }
  if (msg.action === 'progress') {
    updateProgressInList(msg.downloads);
  }
});

function updateProgressInList(downloads) {
  if (!downloads) return;
  downloads.forEach(({ id, state, percent, speed }) => {
    const el = document.querySelector(`[data-id="${id}"]`);
    if (!el) return;
    const meta = el.querySelector('.link-meta');
    if (meta) {
      const pct = percent != null ? `${percent.toFixed(1)}%` : '';
      const spd = speed > 0 ? formatSpeed(speed) : '';
      meta.textContent = [pct, spd, state].filter(Boolean).join('  ·  ');
    }
  });
}

function formatSpeed(bps) {
  if (bps < 1024) return bps.toFixed(0) + ' B/s';
  if (bps < 1024 ** 2) return (bps / 1024).toFixed(1) + ' KB/s';
  return (bps / 1024 ** 2).toFixed(1) + ' MB/s';
}

// ---- Filename resolution ----------------------------------------------------

const GENERIC_NAMES = /^(master|index|playlist|stream|video|audio|media|hls)(\.\w+)?$/i;

function _cleanPageTitle(title) {
  if (!title) return null;
  const cleaned = title.split(/\s[\|\-–—]\s/).shift().trim();
  return cleaned || title;
}

function _resolveFilename(filename, pageTitle) {
  const name = filename ? filename.split('?')[0].split('/').pop() : null;
  if (!name || GENERIC_NAMES.test(name)) return _cleanPageTitle(pageTitle) || null;
  return name;
}

// ---- Send -------------------------------------------------------------------

function _buildPayload(item, openDialog) {
  return {
    action: 'add-url',
    url: item.url,
    openDialog,
    options: {
      filename: _resolveFilename(item.filename, item.pageTitle) ?? undefined,
      description: item.pageTitle ? _cleanPageTitle(item.pageTitle) : undefined,
      headers: item.requestHeaders ?? undefined,
      metadata: {
        ...(item.mime ? { mime: item.mime } : {}),
        ...(item.size != null ? { size: String(item.size) } : {}),
        fromExtension: 'true',
      },
    },
  };
}

function sendUrl(item, btn) {
  btn.disabled = true;
  chrome.runtime.sendMessage(_buildPayload(item, false), (res) => {
    if (res?.ok) {
      btn.textContent = '✓';
      btn.classList.add('sent');
    } else {
      btn.disabled = false;
      btn.textContent = '✗';
    }
  });
}

// ---- Render -----------------------------------------------------------------

function renderItems(items) {
  if (items.length === 0) { show('state-empty'); return; }

  const list = document.getElementById('link-list');
  list.innerHTML = '';

  items.forEach((item) => {
    const { url, filename, pageTitle, size, source, isHls } = item;
    const li = document.createElement('li');
    li.className = 'link-item';
    li.dataset.id = url;

    const displayName = pageTitle || filename;
    const hlsTag = isHls ? '<span class="tag-hls">HLS</span>' : '';
    const meta = [isHls ? null : (source === 'dynamic' ? '● live' : '○ static'), formatSize(size)]
      .filter(Boolean).join('  ·  ');

    li.innerHTML = `
      <div class="link-info">
        <div class="link-name" title="${displayName}">${displayName}</div>
        <div class="link-meta">${hlsTag}${meta}</div>
        <div class="link-url" title="${url}">${url}</div>
      </div>
      <button class="btn-send">Send</button>
    `;
    li._dlxItem = item;
    li.querySelector('.btn-send').addEventListener('click', (e) =>
      sendUrl(item, e.currentTarget)
    );
    list.appendChild(li);
  });

  document.getElementById('btn-all').addEventListener('click', (e) => {
    e.currentTarget.disabled = true;
    list.querySelectorAll('.btn-send:not(.sent):not(:disabled)').forEach(btn => {
      const li = btn.closest('.link-item');
      sendUrl(li._dlxItem, btn);
    });
  });

  document.getElementById('btn-clear').addEventListener('click', () => {
    chrome.runtime.sendMessage({ action: 'clear-captured' }, () => {
      list.innerHTML = '';
      show('state-empty');
    });
  });

  show('state-list');
}

function loadItems() {
  show('state-scanning');
  chrome.runtime.sendMessage({ action: 'get-captured' }, (res) => {
    const dynamic = (res?.items ?? []).map(i => ({ ...i, source: 'dynamic' }));

    chrome.runtime.sendMessage({ action: 'scan-tab' }, (res2) => {
      const seen = new Set(dynamic.map(i => i.url));
      const staticLinks = (res2?.links ?? [])
        .filter(l => !seen.has(l.url))
        .map(l => ({ ...l, source: 'static' }));

      renderItems([...dynamic, ...staticLinks]);
    });
  });
}

// ---- Boot -------------------------------------------------------------------

checkConnection();
