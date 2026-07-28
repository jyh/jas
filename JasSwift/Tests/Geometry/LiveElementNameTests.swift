import Testing
@testable import JasLib

/// ANY ELEMENT CARRIES A NAME — live kinds included.
///
/// The name is the artist's own label for an element; it maps to SVG
/// `inkscape:label`, and jas_dioxus stores it in the `CommonProps` that all
/// four live conformers hold. This port held no `name` on any of them until
/// 2026-07-27, and `LiveElement.swift` carried a comment asserting that as
/// intent ("No name field is intended for live elements") while the reference
/// port disagreed. Measured before the repair: feeding both roundtrip binaries
/// a compound carrying `"name": "hull"`, Rust returned `"name":"hull"` and
/// this port returned `"name":null`.
///
/// WHAT THIS FILE IS FOR, next to the corpus. `test_fixtures/expected/live_named*.json`
/// pin the three CODECS (test_json, binary, SVG) against shared goldens. These
/// batteries pin the MODEL SEAM the codecs sit on: the accessor, the setter,
/// and the two walks that must carry a name through an edit. A codec golden
/// cannot distinguish "the accessor is right" from "the writer happens to read
/// the field directly", and the accessor is what the Layers panel calls.
///
/// Every assertion here names a VALUE. None of them is a whole-struct
/// comparison or a `Mirror` walk: those are structurally blind to a field the
/// struct does not have, which is exactly how this defect survived.
@Suite struct LiveElementNameTests {

    // MARK: - Fixtures, one per live kind, each NAMED and otherwise rich

    private func namedCompound() -> CompoundShape {
        CompoundShape(
            operation: .union,
            operands: [.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                  name: "port", id: "op-back")),
                       .rect(Rect(x: 5, y: 0, width: 10, height: 10,
                                  name: "starboard", id: "op-front"))],
            name: "hull",
            id: "cs-1")
    }

    private func namedReference() -> ReferenceElem {
        ReferenceElem(target: ElementRef("op-back"), name: "eye", id: "ref-1")
    }

    private func namedRecorded() -> RecordedElem {
        RecordedElem(
            ops: [PrimitiveOp(op: "copy",
                              params: ["from": ["src"], "dx": 0.0, "dy": 0.0],
                              targets: [])],
            inputs: [ElementRef("src")],
            name: "stamp",
            id: "rec-1")
    }

    private func namedGenerated() -> GeneratedElem {
        GeneratedElem(conceptId: "regular_polygon",
                      params: ["sides": 6.0, "radius": 50.0],
                      name: "gear",
                      id: "gen-1")
    }

    // MARK: - The accessor, per kind

    /// `Element.name` reaches the name of EVERY live kind. Its `.live` arm used
    /// to be a hard `return nil`, which is why the Layers panel could not label
    /// a compound shape the artist had named.
    @Test func elementNameReadsEveryLiveKind() {
        #expect(Element.live(.compoundShape(namedCompound())).name == "hull")
        #expect(Element.live(.reference(namedReference())).name == "eye")
        #expect(Element.live(.recorded(namedRecorded())).name == "stamp")
        #expect(Element.live(.generated(namedGenerated())).name == "gear")
    }

    /// The same read through the variant, which is what `Element.name` delegates
    /// to. Both are pinned because either one alone could be the broken half.
    @Test func liveVariantNameReadsEveryKind() {
        #expect(LiveVariant.compoundShape(namedCompound()).name == "hull")
        #expect(LiveVariant.reference(namedReference()).name == "eye")
        #expect(LiveVariant.recorded(namedRecorded()).name == "stamp")
        #expect(LiveVariant.generated(namedGenerated()).name == "gear")
    }

    /// An UNNAMED live element reads nil rather than "" — the null/empty
    /// distinction the canonical JSON depends on (`"name":null`).
    @Test func unnamedLiveElementReadsNil() {
        let cs = CompoundShape(operation: .union, operands: [], name: nil)
        #expect(Element.live(.compoundShape(cs)).name == nil)
    }

    // MARK: - The setter

    /// `Element.withName` stamps a live element like any other, and leaves the
    /// rest alone. jas_dioxus writes this through the generic
    /// `common_mut().name`, so a rename has to reach a compound here too.
    @Test func withNameStampsEveryLiveKindAndPreservesTheRest() {
        let renamed = Element.live(.compoundShape(namedCompound())).withName("keel")
        #expect(renamed.name == "keel")
        // Speaks to the name, preserves the rest.
        #expect(renamed.id == "cs-1")
        guard case .live(.compoundShape(let cs)) = renamed else {
            Issue.record("withName changed the element kind"); return
        }
        #expect(cs.operation == .union)
        #expect(cs.operands.count == 2)
        #expect(cs.operands[0].name == "port")
        #expect(cs.operands[1].name == "starboard")

        #expect(Element.live(.reference(namedReference())).withName("iris").name == "iris")
        #expect(Element.live(.recorded(namedRecorded())).withName("seal").name == "seal")
        #expect(Element.live(.generated(namedGenerated())).withName("cog").name == "cog")
    }

    /// Passing nil CLEARS the name (the un-name direction), on a live element
    /// as on any other.
    @Test func withNameNilClearsALiveName() {
        #expect(Element.live(.compoundShape(namedCompound())).withName(nil).name == nil)
    }

    // MARK: - The walks that must carry a name through an edit

    /// `clearingIds` speaks to IDENTITY-BY-ID and to nothing else: the name is
    /// the artist's label and survives a duplication, at the compound AND at
    /// every operand (EDIT_SEMANTICS_FREEZE.md — an edit changes what it speaks
    /// to and preserves the rest).
    @Test func clearingIdsPreservesLiveNamesAtEveryDepth() {
        let cleared = Element.live(.compoundShape(namedCompound())).clearingIds()
        #expect(cleared.id == nil, "the copy must be born id-less")
        #expect(cleared.name == "hull", "clearing ids must not clear the name")
        guard case .live(.compoundShape(let cs)) = cleared else {
            Issue.record("clearingIds changed the element kind"); return
        }
        #expect(cs.operands[0].id == nil)
        #expect(cs.operands[1].id == nil)
        #expect(cs.operands[0].name == "port")
        #expect(cs.operands[1].name == "starboard")
    }

    /// `withId` speaks to the id alone — the mirror of the battery above, so a
    /// future edit cannot satisfy one by breaking the other.
    @Test func withIdPreservesTheLiveName() {
        let stamped = Element.live(.compoundShape(namedCompound())).withId("cs-9")
        #expect(stamped.id == "cs-9")
        #expect(stamped.name == "hull")
    }

    /// The paste offset speaks to POSITION. A named compound arrives named.
    /// (`test_fixtures/algorithms/paste_translate.json` pins the same claim
    /// against Rust; this is the in-port twin.)
    @Test func translateElementPreservesTheLiveName() {
        let moved = EditClipboard.translateElement(
            .live(.compoundShape(namedCompound())), dx: 24, dy: 24)
        #expect(moved.name == "hull")
        guard case .live(.compoundShape(let cs)) = moved,
              case .rect(let r) = cs.operands[0] else {
            Issue.record("translate changed the element shape"); return
        }
        #expect(r.x == 24 && r.y == 24, "and it still actually moves")
    }

    // MARK: - Equatable

    /// `RecordedElem` and `GeneratedElem` hand-write `==` (their payloads hold
    /// `[String: Any]`, which is not `Equatable`), so a new field is invisible
    /// to equality unless it is added to the list by hand. Two values that
    /// differ ONLY in their name must not compare equal.
    @Test func handWrittenEqualityComparesTheName() {
        var a = namedRecorded()
        a.name = "other"
        #expect(a != namedRecorded(), "RecordedElem == ignored the name")

        var b = namedGenerated()
        b.name = "other"
        #expect(b != namedGenerated(), "GeneratedElem == ignored the name")
    }

    // MARK: - Anti-vacuity

    /// Every fixture above really does carry the name it claims — a battery
    /// whose fixtures decayed to nil would pass on nothing, in both directions.
    @Test func fixturesAreActuallyNamed() {
        #expect(namedCompound().name == "hull")
        #expect(namedReference().name == "eye")
        #expect(namedRecorded().name == "stamp")
        #expect(namedGenerated().name == "gear")
    }
}
