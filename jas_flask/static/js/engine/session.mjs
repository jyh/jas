// Session persistence — save / restore the current document to
// localStorage so a tab refresh or browser close-and-reopen brings
// the user back to where they were.
//
// Mirrors `jas_dioxus/src/workspace/session.rs` in spirit but
// trades MessagePack + base64 for plain JSON. Document.mjs is
// already JSON-serializable (no class hierarchy, just discriminated
// objects); using JSON keeps the storage human-readable and avoids
// pulling in a binary codec dep. Storage cost is ~3x vs MessagePack
// but for V1's element-count target (hundreds, not millions) the
// 5MB localStorage budget is plenty.
//
// Storage shape:
//   "jas_flask_session" → JSON
//     { version: 1, filename: <string>, document: <doc-json>,
//       generation: <number> }
//
// V1 saves a single document. Multi-tab persistence (per Rust's
// `jas_doc:0`, `jas_doc:1`, … manifest) lands when Flask grows tabs.

const SESSION_KEY = "jas_flask_session";
const VERSION = 1;

/**
 * Serialize the model's document into localStorage. Idempotent —
 * safe to call repeatedly. No-op if `localStorage` is unavailable
 * (e.g. private mode where it's blocked).
 */
export function saveSession(model) {
  if (!model || !canUseStorage()) return;
  try {
    const payload = JSON.stringify({
      version: VERSION,
      filename: model.filename,
      document: model.document,
      generation: model.generation,
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
 * `{ filename, document, generation } | null`. Callers (typically
 * canvas_bootstrap on init) construct a Model with the returned
 * document if non-null, otherwise start with emptyDocument().
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
        "— starting from empty document",
      );
      return null;
    }
    if (!obj.document || !Array.isArray(obj.document.layers)) return null;
    return {
      filename: typeof obj.filename === "string" ? obj.filename : null,
      document: obj.document,
      generation: typeof obj.generation === "number" ? obj.generation : 0,
    };
  } catch (e) {
    console.warn("[session] load failed:", e);
    return null;
  }
}

/** Drop the saved session — used after a successful File → New. */
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
