// Module-local point buffers for drag-accumulating tools.
//
// Tools like Pencil and Paintbrush push (x, y) coordinates here on
// each mousemove during a drag, then on mouseup the runtime reads
// the buffer (typically via doc.add_path_from_buffer) and clears it.
//
// JS port of workspace_interpreter/point_buffers.py. Single-threaded
// browser context; a module-local Map suffices.

const _buffers = new Map();

/** Reset the named buffer to empty. */
export function clear(name) {
  _buffers.set(name, []);
}

/** Append (x, y) to the named buffer. */
export function push(name, x, y) {
  let buf = _buffers.get(name);
  if (!buf) {
    buf = [];
    _buffers.set(name, buf);
  }
  buf.push([x, y]);
}

/** Number of points currently in the named buffer. */
export function length(name) {
  const buf = _buffers.get(name);
  return buf ? buf.length : 0;
}

/** Return a shallow copy of the buffer's points as [x, y] pairs. */
export function points(name) {
  const buf = _buffers.get(name);
  return buf ? buf.slice() : [];
}
