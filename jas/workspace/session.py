"""Session persistence — save the open canvases on quit and reload
them on launch so dev iteration doesn't have to redraw test content
every restart.

Layout (mirrors jas_dioxus / JasSwift / jas_ocaml):
    ~/.config/jas/session/
        index.json          tab order, filenames, active-tab pointer
        tabN.jasbin         each tab's document, JAS binary format
                            (cross-port compatible with the other apps;
                            see geometry/binary.py)

The session is rewritten in full on every save (no incremental updates)
— the data volume is tiny and the codec is fast enough that this stays
well under perceptible delay even with several tabs.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Optional

from document.document import Document
from document.artboard import ensure_artboards_invariant
from geometry.binary import binary_to_document, document_to_binary


_SCHEMA_VERSION = 1


def _session_dir() -> str:
    home = os.environ.get("HOME", ".")
    return os.path.join(home, ".config/jas/session")


def _clear_tab_blobs(directory: str) -> None:
    """Wipe existing ``tabN.jasbin`` files so a closed-tab file
    doesn't reappear when the new session has fewer tabs."""
    if not os.path.isdir(directory):
        return
    for name in os.listdir(directory):
        if name.endswith(".jasbin"):
            try:
                os.remove(os.path.join(directory, name))
            except OSError:
                pass


def save_session(tabs: list[tuple[str, Document]],
                 active_index: Optional[int]) -> None:
    """Persist the current open canvases to disk. Best-effort: any
    I/O error is swallowed so a failed session save doesn't block
    app quit. When [tabs] is empty the session directory is cleared
    so the next launch starts fresh."""
    try:
        directory = _session_dir()
        os.makedirs(directory, exist_ok=True)
        _clear_tab_blobs(directory)
        tab_entries = []
        for i, (filename, doc) in enumerate(tabs):
            bin_name = f"tab{i}.jasbin"
            path = os.path.join(directory, bin_name)
            data = document_to_binary(doc, compress=True)
            with open(path, "wb") as f:
                f.write(data)
            tab_entries.append({"filename": filename, "binFile": bin_name})
        manifest = {
            "schemaVersion": _SCHEMA_VERSION,
            "tabs": tab_entries,
            "activeIndex": active_index,
        }
        with open(os.path.join(directory, "index.json"), "w") as f:
            json.dump(manifest, f)
    except OSError as exc:
        print(f"[session] save failed: {exc}", file=sys.stderr)


def load_session() -> Optional[tuple[Optional[int], list[tuple[str, Document]]]]:
    """Reload the session saved by [save_session]. Returns
    ``(active_index, [(filename, document), ...])`` when a session
    is present and at least one tab decoded successfully; ``None``
    otherwise. Individual tab failures are skipped (logged to
    stderr) so a single corrupt blob doesn't lose the rest of the
    session."""
    directory = _session_dir()
    index_path = os.path.join(directory, "index.json")
    if not os.path.isfile(index_path):
        return None
    try:
        with open(index_path, "r") as f:
            manifest = json.load(f)
    except (OSError, ValueError) as exc:
        print(f"[session] load failed: {exc}", file=sys.stderr)
        return None
    version = manifest.get("schemaVersion", 0)
    if version != _SCHEMA_VERSION:
        print(f"[session] unsupported schemaVersion {version}", file=sys.stderr)
        return None
    active_index = manifest.get("activeIndex")
    if not isinstance(active_index, int):
        active_index = None
    restored: list[tuple[str, Document]] = []
    for tab in manifest.get("tabs", []):
        filename = tab.get("filename", "") if isinstance(tab, dict) else ""
        bin_file = tab.get("binFile", "") if isinstance(tab, dict) else ""
        if not filename or not bin_file:
            continue
        path = os.path.join(directory, bin_file)
        if not os.path.isfile(path):
            print(f"[session] missing tab blob {bin_file}", file=sys.stderr)
            continue
        try:
            with open(path, "rb") as f:
                data = f.read()
            doc = binary_to_document(data)
        except (OSError, ValueError) as exc:
            print(f"[session] decode {bin_file} failed: {exc}", file=sys.stderr)
            continue
        # The binary format predates the artboards feature so
        # binary_to_document returns artboards = (). The canvas
        # relies on the at-least-one-artboard invariant; without
        # this fix the restored doc has no artboard frame and
        # centering early-returns, leaving the canvas blank.
        # Mirrors jas_ocaml / jas_dioxus / JasSwift.
        repaired, did_repair = ensure_artboards_invariant(doc.artboards)
        if did_repair:
            import dataclasses
            doc = dataclasses.replace(doc, artboards=repaired)
        restored.append((filename, doc))
    if not restored:
        return None
    return (active_index, restored)


def advance_next_untitled_past(filenames: list[str]) -> None:
    """Push the [Untitled-N] counter so a subsequent fresh-filename
    pick won't collide with any name in [filenames]. Without this,
    restoring a session with [Untitled-2] in it then File→New produces
    a second [Untitled-2] tab — close becomes ambiguous and a save+
    reload loop snowballs duplicates."""
    from document import model as _model
    max_n = _model._next_untitled - 1
    prefix = "Untitled-"
    for fn in filenames:
        if fn.startswith(prefix):
            try:
                n = int(fn[len(prefix):])
                if n > max_n:
                    max_n = n
            except ValueError:
                continue
    _model._next_untitled = max_n + 1
