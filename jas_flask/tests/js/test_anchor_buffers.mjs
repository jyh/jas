// Anchor-buffer module tests — ports
// jas_dioxus/src/interpreter/anchor_buffers.rs's unit tests.

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

import * as ab from "../../static/js/engine/anchor_buffers.mjs";

describe("anchor_buffers", () => {
  beforeEach(() => ab.clear("test"));

  it("push creates a corner anchor with handles at the anchor pos", () => {
    ab.push("test", 10, 20);
    const [a] = ab.anchors("test");
    assert.equal(a.x, 10);
    assert.equal(a.y, 20);
    assert.equal(a.hin_x, 10);
    assert.equal(a.hin_y, 20);
    assert.equal(a.hout_x, 10);
    assert.equal(a.hout_y, 20);
    assert.equal(a.smooth, false);
  });

  it("setLastOutHandle mirrors in-handle around the anchor", () => {
    ab.push("test", 50, 50);
    ab.setLastOutHandle("test", 60, 50);
    const [a] = ab.anchors("test");
    assert.equal(a.hout_x, 60);
    assert.equal(a.hout_y, 50);
    assert.equal(a.hin_x, 40);
    assert.equal(a.hin_y, 50);
    assert.equal(a.smooth, true);
  });

  it("setLastOutHandle on empty is a no-op", () => {
    ab.setLastOutHandle("test", 10, 10); // no throw
    assert.equal(ab.length("test"), 0);
  });

  it("pop drops the last anchor", () => {
    ab.push("test", 0, 0);
    ab.push("test", 10, 0);
    ab.pop("test");
    assert.equal(ab.length("test"), 1);
  });

  it("clear empties the buffer", () => {
    ab.push("test", 0, 0);
    ab.push("test", 10, 0);
    ab.clear("test");
    assert.equal(ab.length("test"), 0);
  });

  it("closeHit needs ≥2 anchors and a position within radius", () => {
    ab.push("test", 100, 100);
    assert.equal(ab.closeHit("test", 102, 102, 8), false); // only 1 anchor
    ab.push("test", 200, 200);
    assert.equal(ab.closeHit("test", 102, 102, 8), true);  // 2.83 < 8
    assert.equal(ab.closeHit("test", 120, 100, 8), false); // outside
  });

  it("anchors returns a shallow copy — caller can't mutate buffer", () => {
    ab.push("test", 1, 2);
    const cps = ab.anchors("test");
    cps[0].x = 999;
    const cps2 = ab.anchors("test");
    assert.equal(cps2[0].x, 1);
  });
});
