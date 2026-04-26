// Session persistence — save / restore the live workspace
// (per-tab documents + a snapshot of the engine state) to
// localStorage so a tab refresh or browser close-and-reopen brings
// the user back to where they were.
//
// Mirrors `jas_dioxus/src/workspace/session.rs` in spirit but trades
// MessagePack + base64 for plain JSON. Document.mjs is already
// JSON-serializable; using JSON keeps the storage human-readable and
// avoids pulling in a binary codec dep.
//
// Storage shape:
//   "jas_flask_session" → JSON
//     { version: 2,
//       documents: [
//         { canvas_id, filename, generation, document },
//         …
//       ],
//       state: { <flat key→value snapshot of store.state> },
//     }
//
// V1 stored a single document (back when Flask had no tab system).
// V2 carries every open tab; V1 payloads are dropped on load — the
// extra effort to migrate them isn't worth the complexity for a UX
// that's still under active development.

const SESSION_KEY = "jas_flask_session";
const VERSION = 2;

/**
 * Serialize the entire workspace to localStorage. `entries` is an
 * array of `{ canvas_id, model }`; `state` is a flat key→value object
 * (typically `store.state`). No-op when localStorage is unavailable.
 */
export function saveSession(entries, state) {
  if (!canUseStorage()) return;
  try {
    const documents = (entries || []).map((e) => ({
      canvas_id: e.canvas_id,
      filename: e.model.filename,
      generation: e.model.generation,
      document: e.model.document,
    }));
    const payload = JSON.stringify({
      version: VERSION,
      documents,
      state: state || {},
    });
    window.localStorage.setItem(SESSION_KEY, payload);
  } catch (e) {
    // QuotaExceededError, security errors, etc. — log but don't
    // throw; persistence is best-effort.
    console.warn("[session] save failed:", e);
  }
}

/**
 * Read the saved session back. Returns
 * `{ documents: [{canvas_id, filename, generation, document}, …],
 *    state: {…} } | null`. Callers use the documents list to recreate
 * tabs and restore each Model; the state object is folded back into
 * the engine store so panel selections / active tool / etc. survive.
 */
export function loadSession() {
  if (!canUseStorage()) return null;
  try {
    const raw = window.localStorage.getItem(SESSION_KEY);
    if (!raw) return null;
    const obj = JSON.parse(raw);
    if (!obj || typeof obj !== "object") return null;
    if (obj.version !== VERSION) {
      console.warn(
        "[session] unsupported version", obj.version,
        "— starting fresh",
      );
      return null;
    }
    const docs = Array.isArray(obj.documents) ? obj.documents : [];
    const cleaned = [];
    for (const d of docs) {
      if (!d || !d.document || !Array.isArray(d.document.layers)) continue;
      cleaned.push({
        canvas_id: typeof d.canvas_id === "string" ? d.canvas_id : null,
        filename: typeof d.filename === "string" ? d.filename : null,
        generation: typeof d.generation === "number" ? d.generation : 0,
        document: d.document,
      });
    }
    return {
      documents: cleaned,
      state: obj.state && typeof obj.state === "object" ? obj.state : {},
    };
  } catch (e) {
    console.warn("[session] load failed:", e);
    return null;
  }
}

/** Drop the saved session — used after a successful File → New All
 * or when the user explicitly clears state. */
export function clearSession() {
  if (!canUseStorage()) return;
  try {
    window.localStorage.removeItem(SESSION_KEY);
  } catch (e) { /* ignore */ }
}

function canUseStorage() {
  return typeof window !== "undefined"
    && typeof window.localStorage !== "undefined"
    && window.localStorage !== null;
}

// Exported for tests so node can probe the storage key without
// owning a window.localStorage shim.
export const _SESSION_KEY = SESSION_KEY;
