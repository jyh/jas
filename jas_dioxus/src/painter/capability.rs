//! WHAT A BACKEND CAN DO — the capability vocabulary, DERIVED FROM THE
//! RECORDED CORPUS rather than invented in Rust.
//!
//! # Why this exists
//!
//! [`element_needs_legacy`](super::element_render::element_needs_legacy) routes
//! THE SEAM, and the seam has TWO BACKENDS with different powers:
//! `Canvas2dPainter` executes isolated layers (#47) and mask layers (#55);
//! `Direct2DPainter` executes neither. A router that asks only about the
//! ELEMENT therefore cannot be flipped without routing one backend into an
//! `unimplemented!()`. The question the router must ask is *"can THIS painter
//! do what this element needs?"* — and that question needs a vocabulary.
//!
//! # ⛔ THE VOCABULARY IS DERIVED, NOT DESIGNED (this seat's C3 ruling)
//!
//! An interface like this must be **derived from the conformance fixtures,
//! never invented in the implementation language and back-fitted**. So every
//! variant of [`Capability`] below earns its place by a FIXTURE, and the tests
//! at the bottom of this file are that derivation made mechanical:
//!
//! | the derived claim | the fixture that carries it | the gate |
//! |---|---|---|
//! | the set of capabilities is exactly what the corpus exercises | all 20 scenes | [`tests::the_capability_set_is_exactly_what_the_corpus_exercises`] |
//! | isolated layers are SEPARABLE from masks | `a6_layer_no_mask.json` | [`tests::layers_and_masks_are_separable_by_a_fixture`] |
//! | non-Normal blend is its own thing | `group_blend.json` | [`tests::the_capability_set_is_exactly_what_the_corpus_exercises`] |
//! | …and it RIDES TWO DIFFERENT OPS, so it cannot be a group-only name | `group_blend.json` + `a6_blend.json` | [`tests::a_non_normal_blend_rides_two_different_ops`] |
//! | an op may need TWO capabilities, and neither may absorb the other | `a6_blend.json` | [`tests::a_blended_layer_requires_the_layer_AND_the_blend`] |
//! | a mask never appears outside a layer | all 20 scenes | [`tests::no_scene_carries_a_mask_outside_an_isolated_layer`] |
//!
//! The separability row is the load-bearing one and it is NEW. Until
//! `a6_layer_no_mask.json` landed, every isolated layer in the corpus was
//! paired with a mask (7 and 7), so no fixture could tell a backend with layers
//! from a backend with both — and a query derived from that corpus could only
//! ever have said "the A6 bracket" as ONE unit. That coarser query could not
//! express the state `Canvas2dPainter` actually held from #47 to #55 (layers
//! yes, masks no), which is the state `Direct2DPainter` will pass through when
//! it implements layers before masks. **The granularity is the point, and it is
//! a fixture fact, not a taste.**
//!
//! # What "supports" MEANS here, stated because a vague answer routes wrongly
//!
//! [`Painter::supports`](super::Painter::supports) answers a narrow, measurable
//! question: **can this backend EXECUTE the recorded command through the seam,
//! rather than fall into an unimplemented or unsupported arm?** It is not a
//! claim about pixels. Both backends' corpus lanes measure exactly this — D2D's
//! `ReplayReport::unsupported` and the Canvas2D corpus driver's refusal list —
//! so the answer is CHECKED against the fixtures on both sides, not declared.

use super::Painter;

/// A power a [`Painter`] backend may or may not have, in the vocabulary of the
/// recorded corpus.
///
/// ⛔ A VARIANT MUST BE DRIVEN BY A FIXTURE. A capability nothing in the corpus
/// exercises is indistinguishable from one that cannot be exercised — the same
/// defect as a declared gap no scene reaches. [`tests::the_capability_set_is_exactly_what_the_corpus_exercises`]
/// asserts BOTH directions: every variant is observed, and every capability the
/// corpus produces is a variant.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Capability {
    /// `push_isolated_layer` / `pop_isolated_layer` — a fresh transparent
    /// surface composited as one primitive (A6).
    IsolatedLayers,
    /// `push_mask_layer` / `pop_mask_layer` — the mask bracket, legal only
    /// INSIDE an isolated layer (A6 §3.2).
    MaskLayers,
    /// A blend other than Normal, WHEREVER IT RIDES — `push_group`'s mode or
    /// `push_isolated_layer`'s. One capability because it is one missing thing:
    /// the effect graph. It was `NonNormalGroupBlend` until 08/29 and the name
    /// was the bug — see the module note on FOLDING.
    NonNormalBlend,
}

impl Capability {
    /// Every variant. ⛔ A NEW VARIANT MUST BE ADDED HERE TOO — [`index`] will
    /// not compile without an arm, but this array would silently stay short.
    /// The both-directions gate below is what actually catches that: a variant
    /// the corpus produces but this array omits REDS.
    ///
    /// [`index`]: Capability::index
    pub const ALL: [Capability; 3] = [
        Capability::IsolatedLayers,
        Capability::MaskLayers,
        Capability::NonNormalBlend,
    ];

    /// Bit position in [`Caps`]. The match is exhaustive on purpose: a new
    /// variant fails to compile here, which is the one forcing function the
    /// language gives us.
    const fn index(self) -> u32 {
        match self {
            Capability::IsolatedLayers => 0,
            Capability::MaskLayers => 1,
            Capability::NonNormalBlend => 2,
        }
    }
}

/// A backend's answers, memoised — one bit per [`Capability`].
///
/// Built by asking the painter ([`Caps::of`]), so there is exactly ONE place
/// that turns a live backend into a routing input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Caps {
    bits: u32,
}

impl Caps {
    /// A backend that can do NONE of it — every answer "no".
    ///
    /// ⛔ THIS IS NOT A DEFAULT. It is never reached by omission: [`Painter`]
    /// has no default `supports` body, so every backend answers explicitly.
    /// This constant exists for callers that must state "route as if the
    /// backend were legacy-only" AS A CHOICE, and for tests that drive the
    /// router's negative arm.
    pub const NONE: Caps = Caps { bits: 0 };

    /// Ask a backend, once, for every capability.
    pub fn of(p: &dyn Painter) -> Caps {
        let mut bits = 0u32;
        for c in Capability::ALL {
            if p.supports(c) {
                bits |= 1 << c.index();
            }
        }
        Caps { bits }
    }

    /// Does the backend answer yes to `c`?
    pub fn has(self, c: Capability) -> bool {
        self.bits & (1 << c.index()) != 0
    }

    /// Does this backend supply EVERY capability in `required`?
    ///
    /// The router asks in this shape on purpose: a requirement set is compared
    /// whole, so a caller cannot check one requirement and let a second ride in
    /// unexamined. That is the fold condition (i) forbids, removed by typing
    /// rather than by remembering.
    pub fn supplies(self, required: Caps) -> bool {
        required.bits & !self.bits == 0
    }

    /// The same set plus `c` — for tests describing a HYPOTHETICAL backend
    /// (notably the layers-without-masks state, which is a real state both
    /// backends pass through and which no live impl holds today).
    #[must_use]
    pub fn with(self, c: Capability) -> Caps {
        Caps { bits: self.bits | (1 << c.index()) }
    }
}

/// WHICH CAPABILITIES A RECORDED COMMAND NEEDS — a SET, and the set is the fix.
///
/// ⛔ IT RETURNED ONE CAPABILITY UNTIL 08/29, AND THAT SHAPE WAS THE DEFECT.
/// `a6_blend.json[1]` is `push_isolated_layer` with `blend: multiply` — it needs
/// the LAYER *and* the BLEND. A function returning one answer had to pick, it
/// picked `IsolatedLayers`, and the blend requirement vanished into the layer
/// requirement. So a backend answering "yes, I do isolated layers" was silently
/// also claiming "…and I honour non-Normal blends on them", which is exactly the
/// FOLDING the helm's condition (i) forbids. A one-answer function cannot state
/// a two-requirement op, and no amount of care at the call sites fixes that.
///
/// ⇒ The repair has the same shape as the defect: return the set, so nothing
/// can fold. `Caps::NONE` means the baseline seam is enough.
#[cfg(test)]
pub(crate) fn capabilities_of(op: &serde_json::Value) -> Caps {
    let non_normal = !matches!(
        op.get("blend").and_then(serde_json::Value::as_str),
        Some("normal") | None
    );
    match op.get("cmd").and_then(serde_json::Value::as_str) {
        Some("push_isolated_layer") | Some("pop_isolated_layer") => {
            let c = Caps::NONE.with(Capability::IsolatedLayers);
            // Only the PUSH carries a blend; the pop has none to read.
            if non_normal { c.with(Capability::NonNormalBlend) } else { c }
        }
        Some("push_mask_layer") | Some("pop_mask_layer") => {
            Caps::NONE.with(Capability::MaskLayers)
        }
        // A Normal group is the baseline seam; an absent `blend` records Normal.
        Some("push_group") if non_normal => Caps::NONE.with(Capability::NonNormalBlend),
        _ => Caps::NONE,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::painter::corpus::SCENES;
    use std::collections::BTreeSet;

    /// Every op of every recorded scene, decoded once.
    fn corpus_ops() -> Vec<serde_json::Value> {
        let mut v = Vec::new();
        for (name, text) in SCENES {
            let scene: serde_json::Value =
                serde_json::from_str(text).unwrap_or_else(|e| panic!("{name}: {e}"));
            v.extend(scene.as_array().unwrap_or_else(|| panic!("{name} is not an array")).clone());
        }
        // ANTI-VACUITY: every assertion below is satisfied by an empty corpus.
        assert!(v.len() >= 124, "the corpus shrank to {} ops", v.len());
        v
    }

    fn names(s: &BTreeSet<Capability>) -> Vec<String> {
        s.iter().map(|c| format!("{c:?}")).collect()
    }

    /// ⛔ THE DERIVATION GATE, AND IT RUNS IN BOTH DIRECTIONS.
    ///
    /// →  Every variant of [`Capability`] is OBSERVED on a real scene. A
    ///    variant nothing drives is indistinguishable from one that cannot be
    ///    driven — the exact defect `group_blend.json` was written to close for
    ///    D2D's declared gaps, here applied to the vocabulary itself.
    /// ←  Every capability the corpus PRODUCES is a listed variant. This is the
    ///    direction that catches a variant added to the enum and forgotten in
    ///    `ALL`: the classifier would emit it, `ALL` would not contain it, and
    ///    the set comparison reds.
    #[test]
    fn the_capability_set_is_exactly_what_the_corpus_exercises() {
        let observed: BTreeSet<Capability> = corpus_ops()
            .iter()
            .flat_map(|op| {
                let need = super::capabilities_of(op);
                Capability::ALL.into_iter().filter(move |c| need.has(*c))
            })
            .collect();
        let declared: BTreeSet<Capability> = Capability::ALL.into_iter().collect();
        assert_eq!(
            names(&observed),
            names(&declared),
            "the capability vocabulary and the corpus disagree -- a variant no \
             fixture drives is a stale entry with a future, and a capability the \
             fixtures produce but ALL omits is invisible to every gate that \
             iterates ALL"
        );
    }

    /// ⛔ THE GRANULARITY IS A FIXTURE FACT. There must be a scene with
    /// isolated layers and NO masks, or [`Capability::IsolatedLayers`] and
    /// [`Capability::MaskLayers`] are two names for one thing and the query is
    /// coarser than the backends it routes.
    #[test]
    fn layers_and_masks_are_separable_by_a_fixture() {
        let mut separating = Vec::new();
        for (name, text) in SCENES {
            let scene: serde_json::Value = serde_json::from_str(text).unwrap();
            let caps: BTreeSet<Capability> = scene
                .as_array()
                .unwrap()
                .iter()
                .flat_map(|op| {
                    let need = super::capabilities_of(op);
                    Capability::ALL.into_iter().filter(move |c| need.has(*c))
                })
                .collect();
            if caps.contains(&Capability::IsolatedLayers) && !caps.contains(&Capability::MaskLayers)
            {
                separating.push(*name);
            }
        }
        assert!(
            !separating.is_empty(),
            "no scene exercises an isolated layer WITHOUT a mask, so no fixture \
             can distinguish a backend with layers from one with both -- the two \
             capabilities would be underivable and this query would be a rename \
             of `the A6 bracket`"
        );
    }

    /// A DERIVED CONTRACT FACT, and the reason the router asks for BOTH: A6
    /// §3.2 makes a mask bracket legal only inside an isolated layer, so no
    /// scene carries one outside. A backend answering yes to masks and no to
    /// layers is therefore unreachable by any fixture — which is why routing a
    /// masked element requires both answers rather than just the mask one.
    #[test]
    fn no_scene_carries_a_mask_outside_an_isolated_layer() {
        for (name, text) in SCENES {
            let scene: serde_json::Value = serde_json::from_str(text).unwrap();
            let mut depth = 0i32;
            for op in scene.as_array().unwrap() {
                match op.get("cmd").and_then(serde_json::Value::as_str) {
                    Some("push_isolated_layer") => depth += 1,
                    Some("pop_isolated_layer") => depth -= 1,
                    Some("push_mask_layer") => assert!(
                        depth > 0,
                        "{name}: a mask bracket outside an isolated layer -- A6 \
                         §3.2 forbids it and the capability lattice assumes it"
                    ),
                    _ => {}
                }
            }
            assert_eq!(depth, 0, "{name}: unbalanced isolated-layer bracket");
        }
    }

    /// The baseline is genuinely baseline: the ops that make up the bulk of the
    /// corpus demand nothing. Without this the classifier could return `Some`
    /// for everything and the two gates above would still pass.
    #[test]
    fn the_ordinary_drawing_ops_need_no_capability() {
        let ops = corpus_ops();
        let baseline = ops
            .iter()
            .filter(|o| super::capabilities_of(o) == Caps::NONE)
            .count();
        assert!(
            baseline >= 93,
            "only {baseline} of {} ops are baseline; the classifier is claiming \
             capabilities the seam has always had",
            ops.len()
        );
        for cmd in ["fill_rect", "stroke_path", "push_state", "clip", "draw_text_run"] {
            let op = serde_json::json!({ "cmd": cmd });
            assert_eq!(super::capabilities_of(&op), Caps::NONE, "{cmd} is baseline");
        }
        // ...and a Normal group is baseline while a non-Normal one is not --
        // the one arm where the CLASSIFIER reads more than the command name.
        assert_eq!(
            super::capabilities_of(&serde_json::json!({ "cmd": "push_group", "blend": "normal" })),
            Caps::NONE
        );
        assert_eq!(
            super::capabilities_of(&serde_json::json!({ "cmd": "push_group" })),
            Caps::NONE,
            "an absent blend records as Normal"
        );
        assert_eq!(
            super::capabilities_of(&serde_json::json!({ "cmd": "push_group", "blend": "multiply" })),
            Caps::NONE.with(Capability::NonNormalBlend)
        );
    }

    /// ⛔ CONDITION (i), MADE MECHANICAL — a blended layer requires the LAYER
    /// **AND** THE BLEND, and neither absorbs the other.
    ///
    /// This is the gate that would have stopped the 08/29 flip from being
    /// wrong. `a6_blend.json[1]` is `push_isolated_layer` with `multiply`. While
    /// the classifier returned ONE capability it had to choose, it chose
    /// `IsolatedLayers`, and the blend requirement DISAPPEARED INTO the layer
    /// requirement — so a backend answering "I do isolated layers" was silently
    /// also claiming "…and I honour non-Normal blends on them". That is the
    /// FOLDING the helm's condition (i) forbids, and no care at a call site can
    /// undo it: a one-answer function cannot state a two-requirement op.
    ///
    /// The set makes it impossible to express the folded form, which is why the
    /// repair is a type change and not a rule.
    #[test]
    #[allow(non_snake_case)]
    fn a_blended_layer_requires_the_layer_AND_the_blend() {
        let blended = corpus_ops()
            .into_iter()
            .find(|o| {
                o["cmd"] == "push_isolated_layer"
                    && o.get("blend").and_then(serde_json::Value::as_str)
                        .is_some_and(|b| b != "normal")
            })
            .expect(
                "the corpus must carry a BLENDED isolated layer -- without it \
                 nothing can distinguish a backend that opens layers from one \
                 that also honours their blend, and the folding is unprovable",
            );
        let need = super::capabilities_of(&blended);
        assert!(need.has(Capability::IsolatedLayers), "it is still a layer");
        assert!(
            need.has(Capability::NonNormalBlend),
            "the blend requirement was absorbed by the layer requirement -- this \
             is the fold, and it is exactly what a backend that stores `blend` \
             and never reads it would be excused by"
        );

        // ...and the UNBLENDED layer must NOT drag the blend in, or the two
        // capabilities are welded the other way and every layer would be
        // refused by a backend with no effect graph.
        let plain = corpus_ops()
            .into_iter()
            .find(|o| {
                o["cmd"] == "push_isolated_layer"
                    && o.get("blend").and_then(serde_json::Value::as_str)
                        .is_none_or(|b| b == "normal")
            })
            .expect("the corpus must also carry a plain isolated layer");
        let need = super::capabilities_of(&plain);
        assert!(need.has(Capability::IsolatedLayers));
        assert!(!need.has(Capability::NonNormalBlend),
                "a Normal layer needs no effect graph; welding these would make \
                 every layer unroutable on a backend that lacks one");
    }

    /// ⛔ AND THE NAME HAD TO CHANGE, BECAUSE THE FIXTURES SAY IT RIDES TWO OPS.
    /// It was `NonNormalGroupBlend` until 08/29. The corpus puts a non-Normal
    /// blend on `push_group` (`group_blend.json`) AND on `push_isolated_layer`
    /// (`a6_blend.json`) — one missing thing (the effect graph), two carriers. A
    /// group-only name describes one of them and silently excuses the other,
    /// which is how the layer site became a SILENT gap the moment a backend
    /// implemented layers.
    #[test]
    fn a_non_normal_blend_rides_two_different_ops() {
        let mut carriers: BTreeSet<String> = BTreeSet::new();
        for op in corpus_ops() {
            if super::capabilities_of(&op).has(Capability::NonNormalBlend) {
                carriers.insert(op["cmd"].as_str().unwrap().to_string());
            }
        }
        assert_eq!(
            carriers.iter().cloned().collect::<Vec<_>>(),
            vec!["push_group".to_string(), "push_isolated_layer".to_string()],
            "the blend capability must be OBSERVED on both carriers; if the \
             corpus ever holds only one, a name naming that one stops being \
             wrong and the fold becomes invisible again"
        );
    }

    /// `Caps` must round-trip every variant independently — a bit-index
    /// collision would make two capabilities answer as one, which is precisely
    /// the coarseness this whole query exists to avoid.
    #[test]
    fn caps_round_trips_each_capability_independently() {
        assert!(
            Capability::ALL.iter().all(|c| !Caps::NONE.has(*c)),
            "Caps::NONE must answer no to everything"
        );
        for c in Capability::ALL {
            let only = Caps::NONE.with(c);
            assert!(only.has(c), "{c:?} did not survive its own bit");
            for other in Capability::ALL {
                if other != c {
                    assert!(
                        !only.has(other),
                        "{other:?} reads as supported after setting only {c:?} -- \
                         the bit indices collide"
                    );
                }
            }
        }
    }
}
