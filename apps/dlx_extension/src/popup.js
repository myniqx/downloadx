"use strict";

function show(id) {
  ['state-scanning', 'state-empty', 'state-list', 'state-error'].forEach(s =>
    document.getElementById(s).classList.toggle('hidden', s !== id)
  );
}

function formatSize(bytes) {
  if (!bytes) return '';
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 ** 2) return (bytes / 1024).toFixed(1) + ' KB';
  if (bytes < 1024 ** 3) return (bytes / 1024 ** 2).toFixed(1) + ' MB';
  return (bytes / 1024 ** 3).toFixed(2) + ' GB';
}

function sendUrl(url, filename, btn) {
  btn.disabled = true;
  chrome.runtime.sendMessage({ action: 'add-url', url, filename }, (res) => {
    if (res?.ok) {
      btn.textContent = '✓';
      btn.classList.add('sent');
    } else {
      btn.disabled = false;
      btn.textContent = '✗';
    }
  });
}

function renderItems(items) {
  if (items.length === 0) { show('state-empty'); return; }

  const list = document.getElementById('link-list');
  list.innerHTML = '';

  items.forEach(({ url, filename, pageTitle, size, source, isHls }) => {
    const li = document.createElement('li');
    li.className = 'link-item';

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
    li.querySelector('.btn-send').addEventListener('click', (e) =>
      sendUrl(url, pageTitle || null, e.currentTarget)
    );
    list.appendChild(li);
  });

  document.getElementById('btn-all').addEventListener('click', (e) => {
    e.currentTarget.disabled = true;
    list.querySelectorAll('.btn-send:not(.sent):not(:disabled)').forEach(btn => {
      const li = btn.closest('.link-item');
      sendUrl(li.querySelector('.link-url').title, null, btn);
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

// Connection status indicator.
chrome.runtime.sendMessage({ action: 'get-status' }, (res) => {
  const badge = document.getElementById('conn-badge');
  if (res?.connected) {
    badge.title = 'dlx is running';
    badge.classList.add('connected');
  } else {
    badge.title = 'dlx is not running';
  }
});

// 1. Get dynamically captured items.
chrome.runtime.sendMessage({ action: 'get-captured' }, (res) => {
  const dynamic = (res?.items ?? []).map(i => ({ ...i, source: 'dynamic' }));

  // 2. Scan static links in page — merge, deduplicate by URL.
  chrome.runtime.sendMessage({ action: 'scan-tab' }, (res2) => {
    const seen = new Set(dynamic.map(i => i.url));
    const staticLinks = (res2?.links ?? [])
      .filter(l => !seen.has(l.url))
      .map(l => ({ ...l, source: 'static' }));

    renderItems([...dynamic, ...staticLinks]);
  });
});
