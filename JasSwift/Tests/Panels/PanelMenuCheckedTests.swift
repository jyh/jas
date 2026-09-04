import Foundation
import Testing
@testable import JasLib

// ── Panel-menu `checked_when` through the generic evaluator ──────
//
// These probe `panelIsChecked` — the one function the hamburger menu
// asks for every check mark. Until this landed the answer came from
// fourteen per-panel native hooks; BrushesPanel's hand-implemented three
// of the Brushes panel's four predicate families in Swift and returned
// `false` for the fourth, while jas_dioxus returned `false` for all of
// them. The predicates were in `workspace/panels/brushes.yaml` the whole
// time.
//
// The arms below are written against the YAML's DECLARED defaults, so a
// port that stops reading the bundle reds rather than drifting quietly.

private let brushesPid = "brushes_panel_content"

private func brushesModel() -> Model {
    let model = Model()
    let ws = WorkspaceData.load()!
    model.stateStore.initPanel(brushesPid, defaults: ws.panelStateDefaults(brushesPid))
    return model
}

/// RED before the generic evaluator: `BrushesPanel.isCheckedWithModel`
/// had no arm for `toggle_brush_library_persistent` and fell through to
/// `return false`, so "Make Persistent" never showed a check mark even
/// for a library that IS persistent. The predicate
/// (`any(preferences.brushes.persistent_libraries, fun lib -> lib ==
/// panel.selected_library)`) reads a namespace no native hook consulted.
@Test func makePersistentFollowsThePreferencesList() {
    let layout = WorkspaceLayout.defaultLayout()
    let model = brushesModel()
    // brushes.yaml declares `selected_library: default_brushes`, and
    // preferences.yaml lists `default_brushes` as persistent.
    #expect(panelIsChecked(.brushes, cmd: "toggle_brush_library_persistent",
                           layout: layout, model: model))
    // A library that is not in the preference is not checked — so the
    // arm above cannot pass by returning a constant.
    model.stateStore.setPanel(brushesPid, "selected_library", "my_library")
    #expect(!panelIsChecked(.brushes, cmd: "toggle_brush_library_persistent",
                            layout: layout, model: model))
}

@Test func brushCategoryCheckMarksFollowTheFilterList() {
    let layout = WorkspaceLayout.defaultLayout()
    let model = brushesModel()
    let categories = ["calligraphic", "scatter", "art", "pattern", "bristle"]
    // The declared default lists all five.
    for cat in categories {
        #expect(panelIsChecked(.brushes, cmd: "toggle_brush_category:\(cat)",
                               layout: layout, model: model),
                "Show \(cat) Brushes should start checked")
    }
    // Exactly one lit: a set of five predicates collapsed to one reds here.
    model.stateStore.setPanel(brushesPid, "category_filter", ["art"])
    for cat in categories {
        #expect(panelIsChecked(.brushes, cmd: "toggle_brush_category:\(cat)",
                               layout: layout, model: model) == (cat == "art"),
                "only Art should be checked; \(cat) disagreed")
    }
}

@Test func brushViewModeAndThumbnailSizeRadiosFollowPanelState() {
    let layout = WorkspaceLayout.defaultLayout()
    let model = brushesModel()
    #expect(panelIsChecked(.brushes, cmd: "set_brush_view_mode:thumbnail",
                           layout: layout, model: model))
    #expect(!panelIsChecked(.brushes, cmd: "set_brush_view_mode:list",
                            layout: layout, model: model))
    model.stateStore.setPanel(brushesPid, "view_mode", "list")
    #expect(!panelIsChecked(.brushes, cmd: "set_brush_view_mode:thumbnail",
                            layout: layout, model: model))
    #expect(panelIsChecked(.brushes, cmd: "set_brush_view_mode:list",
                           layout: layout, model: model))

    for size in ["small", "medium", "large"] {
        model.stateStore.setPanel(brushesPid, "thumbnail_size", size)
        for probe in ["small", "medium", "large"] {
            #expect(panelIsChecked(.brushes, cmd: "set_brush_thumbnail_size:\(probe)",
                                   layout: layout, model: model) == (probe == size),
                    "thumbnail_size=\(size): \(probe) disagreed")
        }
    }
}

/// The panels whose check marks already worked through a native hook must
/// keep working once the hooks are gone: the generic context has to publish
/// the same live values the hooks read.
@Test func nativePanelsKeepTheirCheckMarksThroughTheGenericPath() {
    var layout = WorkspaceLayout.defaultLayout()
    let model = Model()
    let ws = WorkspaceData.load()!

    // Color: the mode lives on WorkspaceLayout, not the panel store.
    layout.colorPanelMode = .cmyk
    #expect(panelIsChecked(.color, cmd: "set_color_panel_mode:cmyk",
                           layout: layout, model: model))
    #expect(!panelIsChecked(.color, cmd: "set_color_panel_mode:rgb",
                            layout: layout, model: model))

    // Opacity: four independent toggles, also on WorkspaceLayout.
    layout.opacityPanel.thumbnailsHidden = true
    layout.opacityPanel.optionsShown = false
    layout.opacityPanel.newMasksClipping = false
    layout.opacityPanel.newMasksInverted = true
    #expect(panelIsChecked(.opacity, cmd: "toggle_opacity_thumbnails",
                           layout: layout, model: model))
    #expect(!panelIsChecked(.opacity, cmd: "toggle_opacity_options",
                            layout: layout, model: model))
    #expect(!panelIsChecked(.opacity, cmd: "toggle_new_masks_clipping",
                            layout: layout, model: model))
    #expect(panelIsChecked(.opacity, cmd: "toggle_new_masks_inverted",
                           layout: layout, model: model))

    // Stroke / Swatches / Character / Paragraph / Align: the panel store.
    for pid in ["stroke_panel_content", "swatches_panel_content",
                "character_panel_content", "paragraph_panel_content",
                "align_panel_content"] {
        model.stateStore.initPanel(pid, defaults: ws.panelStateDefaults(pid))
    }
    model.stateStore.setPanel("stroke_panel_content", "cap", "round")
    model.stateStore.setPanel("stroke_panel_content", "join", "bevel")
    #expect(panelIsChecked(.stroke, cmd: "set_stroke_cap:round",
                           layout: layout, model: model))
    #expect(!panelIsChecked(.stroke, cmd: "set_stroke_cap:butt",
                            layout: layout, model: model))
    #expect(panelIsChecked(.stroke, cmd: "set_stroke_join:bevel",
                           layout: layout, model: model))
    #expect(!panelIsChecked(.stroke, cmd: "set_stroke_join:miter",
                            layout: layout, model: model))

    model.stateStore.setPanel("swatches_panel_content", "thumbnail_size", "medium")
    #expect(panelIsChecked(.swatches, cmd: "set_swatch_thumbnail_size:medium",
                           layout: layout, model: model))
    #expect(!panelIsChecked(.swatches, cmd: "set_swatch_thumbnail_size:small",
                            layout: layout, model: model))

    // character.yaml / paragraph.yaml / align.yaml spell the predicate
    // `checked:` rather than `checked_when:` — the reader has to accept
    // both spellings or these three panels' check marks die.
    model.stateStore.setPanel("character_panel_content", "all_caps", true)
    model.stateStore.setPanel("character_panel_content", "small_caps", false)
    #expect(panelIsChecked(.character, cmd: "toggle_all_caps",
                           layout: layout, model: model))
    #expect(!panelIsChecked(.character, cmd: "toggle_small_caps",
                            layout: layout, model: model))

    model.stateStore.setPanel("paragraph_panel_content", "hanging_punctuation", true)
    #expect(panelIsChecked(.paragraph, cmd: "toggle_hanging_punctuation",
                           layout: layout, model: model))

    model.stateStore.setPanel("align_panel_content", "use_preview_bounds", true)
    #expect(panelIsChecked(.align, cmd: "toggle_use_preview_bounds",
                           layout: layout, model: model))
    model.stateStore.setPanel("align_panel_content", "use_preview_bounds", false)
    #expect(!panelIsChecked(.align, cmd: "toggle_use_preview_bounds",
                            layout: layout, model: model))
}
