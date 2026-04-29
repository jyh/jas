// Module-local anchor buffers — the Pen tool's accumulator.
//
// Distinct from point_buffers (Pencil's freehand) because each entry
// carries Bezier handle info: x, y, in-handle (hin_x, hin_y),
// out-handle (hout_x, hout_y), and a smooth/corner flag. `corner` →
// the click landed without a drag, both handles coincide with the
// anchor; `smooth` → the user dragged on the click, the runtime ran
// set_last_out which sets the out-handle and mirrors the in-handle
// around the anchor.
//
// Ports `jas_dioxus/src/interpreter/anchor_buffers.rs`.

const _buffers = new Map();

/** Append a corner anchor at (x, y). Both handles coincide with the
 * anchor position; subsequent set_last_out converts to smooth. */
export function push(name, x, y) {
  let buf = _buffers.get(name);
  if (!buf) { buf = []; _buffers.set(name, buf); }
  buf.push({
    x, y,
    hin_x: x, hin_y: y,
    hout_x: x, hout_y: y,
    smooth: false,
  });
}

/** Drop the last anchor. No-op if the buffer is empty. */
export function pop(name) {
  const buf = _buffers.get(name);
  if (buf && buf.length > 0) buf.pop();
}

/** Reset the named buffer. */
export function clear(name) {
  _buffers.delete(name);
}

/** Number of anchors in the named buffer. */
export function length(name) {
  const buf = _buffers.get(name);
  return buf ? buf.length : 0;
}

/** Set the last anchor's out-handle to (hx, hy) and mirror the
 * in-handle around the anchor. Flips smooth to true. No-op if the
 * buffer is empty. */
export function setLastOutHandle(name, hx, hy) {
  const buf = _buffers.get(name);
  if (!buf || buf.length === 0) return;
  const last = buf[buf.length - 1];
  last.hout_x = hx;
  last.hout_y = hy;
  last.hin_x = 2 * last.x - hx;
  last.hin_y = 2 * last.y - hy;
  last.smooth = true;
}

/** Read-only access to the buffer's anchors. Returns a shallow copy
 * of each anchor object. */
export function anchors(name) {
  const buf = _buffers.get(name);
  if (!buf) return [];
  return buf.map((a) => ({ ...a }));
}

/** True iff the buffer has at least 2 anchors and (x, y) is within
 * `radius` of the first one — the close-path gesture. */
export function closeHit(name, x, y, radius) {
  const buf = _buffers.get(name);
  if (!buf || buf.length < 2) return false;
  const first = buf[0];
  const dx = x - first.x, dy = y - first.y;
  return dx * dx + dy * dy <= radius * radius;
}
