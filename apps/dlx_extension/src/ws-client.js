"use strict";

const WS_URL = 'ws://127.0.0.1:46582';
const RECONNECT_MS = 3000;

let socket = null;
let connected = false;
const listeners = new Set();

function connect() {
  socket = new WebSocket(WS_URL);

  socket.addEventListener('open', () => {
    connected = true;
    listeners.forEach(fn => fn({ type: 'connect' }));
  });

  socket.addEventListener('message', (e) => {
    try {
      const msg = JSON.parse(e.data);
      listeners.forEach(fn => fn({ type: 'message', msg }));
    } catch {}
  });

  socket.addEventListener('close', () => {
    connected = false;
    listeners.forEach(fn => fn({ type: 'disconnect' }));
    setTimeout(connect, RECONNECT_MS);
  });

  socket.addEventListener('error', () => {
    socket.close();
  });
}

export function startWsClient() {
  connect();
}

export function isConnected() {
  return connected;
}

export function sendWs(msg) {
  if (connected) socket.send(JSON.stringify(msg));
}

export function addWsListener(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}
