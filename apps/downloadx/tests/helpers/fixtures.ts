/**
 * Deterministic byte-payload builders used across tests.
 *
 * Using pseudo-random content makes assertions much stronger than repeating
 * zero bytes: a bug that overlaps chunks or misaligns offsets would silently
 * pass against a zero-filled buffer.
 */
export function makeBytes(size: number, seed = 1): Uint8Array {
  const out = new Uint8Array(size);
  let s = seed >>> 0 || 1;
  for (let i = 0; i < size; i += 1) {
    // xorshift32 — tiny, deterministic, good enough for fixtures.
    s ^= s << 13;
    s ^= s >>> 17;
    s ^= s << 5;
    out[i] = s & 0xff;
  }
  return out;
}

export function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}
