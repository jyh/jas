/// SwiftUI view that renders a panel body from its YAML content spec.
///
/// Maps YAML element types to SwiftUI views: container → VStack/HStack,
/// text → Text, slider → Slider, color_swatch → colored Rectangle, etc.

import SwiftUI
import AppKit

private struct PickerEntry: Identifiable {
    let id: Int
    let val: String
    let displayLabel: String
}

/// Renders a YAML element tree as a SwiftUI view.
struct YamlElementView: View {
    let element: [String: Any]
    let context: [String: Any]
    var model: Model?
    /// ID of the enclosing panel — widget write-backs (onChange) route
    /// through `model.stateStore.setPanel(panelId, key, value)` when
    /// non-nil. `nil` in dialog / non-panel contexts; writes fall back
    /// to the legacy no-op for now.
    var panelId: String? = nil

    var body: some View {
        // Check bind.visible — if the expression evaluates to false, hide the element.
        if !isVisible() {
            EmptyView()
        } else if element["foreach"] != nil && element["do"] != nil {
            // Repeat directive: expand template for each item in source list.
            renderRepeat()
        } else {
            let etype = element["type"] as? String ?? "placeholder"
            switch etype {
            case "container", "row", "col":
                renderContainer()
            case "grid":
                renderGrid()
            case "text":
                renderText()
            case "button":
                renderButton()
            case "icon_button":
                renderIconButton()
            case "slider":
                renderSlider()
            case "number_input":
                renderNumberInput()
            case "text_input":
                renderTextInput()
            case "select":
                renderSelect()
            case "toggle", "checkbox":
                renderToggle()
            case "combo_box":
                renderComboBox()
            case "color_swatch":
                renderColorSwatch()
            case "fill_stroke_widget":
                renderContainer()
            case "separator":
                renderSeparator()
            case "spacer":
                Spacer()
            case "disclosure":
                renderDisclosure()
            case "panel":
                renderPanel()
            case "tree_view":
                renderTreeView()
            case "element_preview":
                renderElementPreview()
            default:
                renderPlaceholder()
            }
        }
    }

    /// Evaluate bind.visible expression. Returns true if no binding or if expression is truthy.
    private func isVisible() -> Bool {
        guard let bind = element["bind"] as? [String: Any],
              let visExpr = bind["visible"] as? String else {
            return true
        }
        return evaluate(visExpr, context: context).toBool()
    }

    /// Extract the write-back key from a `bind.value` / `bind.checked`
    /// expression. Returns the bare panel-scoped key when the expression
    /// is the simple lookup form `panel.some_key`; returns `nil` for
    /// computed expressions (they are treated as read-only for widgets).
    private func writeBackKey(_ expr: String?) -> String? {
        guard let e = expr?.trimmingCharacters(in: .whitespaces),
              e.hasPrefix("panel.") else { return nil }
        let rest = String(e.dropFirst("panel.".count))
        guard !rest.isEmpty,
              rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }
        return rest
    }

    /// Commit a write to the panel state: store → bump version →
    /// fire the `notify_panel_state_changed` hook. No-op when the
    /// target key / panelId / store isn't available.
    ///
    /// For panels whose visible state is driven by selection overrides
    /// (Character panel), sync the overrides into the store *first* so
    /// that the apply-to-selection pipeline sees the complete shown
    /// state. Without this the user's single-field edit would push
    /// stale stored defaults for every *other* attr back onto the
    /// selected element, undoing attrs they hadn't touched.
    private func commitPanelWrite(key: String, value: Any?) {
        guard let model = model, let pid = panelId else { return }
        if pid == "character_panel",
           let overrides = characterPanelLiveOverrides(model: model) {
            for (k, v) in overrides { model.stateStore.setPanel(pid, k, v) }
        }
        model.stateStore.setPanel(pid, key, value)
        model.panelStateVersion &+= 1
        notifyPanelStateChanged(pid, store: model.stateStore, model: model)
    }

    // MARK: - Repeat

    /// Expand a repeat directive: evaluate the source expression to get a list,
    /// then render the template element once per item with the loop variable
    /// injected via Scope for proper static scoping.
    @ViewBuilder
    private func renderRepeat() -> some View {
        let repeatSpec = element["foreach"] as? [String: Any] ?? [:]
        let template = element["do"] as? [String: Any] ?? [:]
        let sourceExpr = repeatSpec["source"] as? String ?? ""
        let varName = repeatSpec["as"] as? String ?? "item"

        // Build scope from context and evaluate source
        let scope = Scope(context)
        let items = evaluateToList(sourceExpr, context: context)

        let layout = element["layout"] as? String ?? "column"
        let gap = (element["style"] as? [String: Any])?["gap"] as? CGFloat ?? 0

        if layout == "wrap" {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 20), spacing: gap)],
                spacing: gap
            ) {
                ForEach(0..<items.count, id: \.self) { i in
                    let childScope = scope.extend(itemBindings(varName, item: items[i], index: i))
                    YamlElementView(element: template, context: childScope.toDict(), model: model, panelId: panelId)
                }
            }
        } else if layout == "row" {
            HStack(spacing: gap) {
                ForEach(0..<items.count, id: \.self) { i in
                    let childScope = scope.extend(itemBindings(varName, item: items[i], index: i))
                    YamlElementView(element: template, context: childScope.toDict(), model: model, panelId: panelId)
                }
            }
        } else {
            VStack(spacing: gap) {
                ForEach(0..<items.count, id: \.self) { i in
                    let childScope = scope.extend(itemBindings(varName, item: items[i], index: i))
                    YamlElementView(element: template, context: childScope.toDict(), model: model, panelId: panelId)
                }
            }
        }
    }

    private func itemBindings(_ varName: String, item: [String: Any], index: Int) -> [String: Any] {
        var data = item
        data["_index"] = index
        return [varName: data]
    }

    /// Evaluate a source expression and return the result as a list of dictionaries.
    /// Handles both direct array values and JSON-serialized results from the evaluator.
    private func evaluateToList(_ expr: String, context: [String: Any]) -> [[String: Any]] {
        let result = evaluate(expr, context: context)
        switch result {
        case .list(let arr):
            // Convert AnyJSON items to [String: Any] dicts
            return arr.map { item in
                if let dict = item.value as? [String: Any] {
                    return dict
                } else {
                    // Wrap scalar values so they can be used in the context
                    return ["value": item.value]
                }
            }
        case .string(let s):
            // The evaluator serializes dicts/arrays to JSON strings;
            // try parsing it back as an array of objects.
            if let data = s.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return parsed
            }
            // Try as array of any
            if let data = s.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                return parsed.map { item in
                    if let dict = item as? [String: Any] { return dict }
                    return ["value": item]
                }
            }
            return []
        default:
            return []
        }
    }

    /// Extend the eval context with the loop variable and its index.
    private func extendContext(_ ctx: [String: Any], varName: String, item: [String: Any], index: Int) -> [String: Any] {
        var extended = ctx
        var itemWithIndex = item
        itemWithIndex["_index"] = index
        extended[varName] = itemWithIndex
        return extended
    }

    // MARK: - Container

    @ViewBuilder
    private func renderContainer() -> some View {
        let layout = element["layout"] as? String ?? "column"
        let etype = element["type"] as? String ?? "container"
        let isRow = layout == "row" || etype == "row"
        let gap = (element["style"] as? [String: Any])?["gap"] as? CGFloat ?? 0

        if isRow {
            HStack(spacing: gap) {
                renderChildElements()
            }
        } else {
            VStack(spacing: gap) {
                renderChildElements()
            }
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private func renderGrid() -> some View {
        let cols = element["cols"] as? Int ?? 2
        let gap = element["gap"] as? CGFloat ?? 0
        let children = element["children"] as? [[String: Any]] ?? []

        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: cols),
            spacing: gap
        ) {
            ForEach(0..<children.count, id: \.self) { i in
                YamlElementView(element: children[i], context: context, model: model, panelId: panelId)
            }
        }
    }

    // MARK: - Text

    @ViewBuilder
    private func renderText() -> some View {
        let content = element["content"] as? String ?? ""
        let text = content.contains("{{")
            ? evaluateText(content, context: context)
            : content
        let fontSize = (element["style"] as? [String: Any])?["font_size"] as? CGFloat ?? 12
        SwiftUI.Text(text)
            .font(.system(size: fontSize))
    }

    // MARK: - Button

    @ViewBuilder
    private func renderButton() -> some View {
        let label = element["label"] as? String ?? ""
        Button(label) { }
    }

    // MARK: - Icon Button

    @ViewBuilder
    private func renderIconButton() -> some View {
        let summary = element["summary"] as? String ?? ""
        Button(summary) { }
            .buttonStyle(.plain)
    }

    // MARK: - Slider

    @ViewBuilder
    private func renderSlider() -> some View {
        let minVal = element["min"] as? Double ?? 0
        let maxVal = element["max"] as? Double ?? 100

        // Get initial value from bind expression
        let initialValue: Double = {
            if let bind = element["bind"] as? [String: Any],
               let valueExpr = bind["value"] as? String {
                let result = evaluate(valueExpr, context: context)
                if case .number(let n) = result { return n }
            }
            return minVal
        }()

        let isDisabled: Bool = {
            if let bind = element["bind"] as? [String: Any],
               let disExpr = bind["disabled"] as? String {
                return evaluate(disExpr, context: context).toBool()
            }
            return false
        }()

        HStack(spacing: 4) {
            SliderView(value: initialValue, range: minVal...maxVal)
                .disabled(isDisabled)
        }
    }

    // MARK: - Number Input

    @ViewBuilder
    private func renderNumberInput() -> some View {
        let minVal = element["min"] as? Int ?? 0
        let bind = element["bind"] as? [String: Any]
        let valueExpr = bind?["value"] as? String
        let currentValue: Int = {
            if let e = valueExpr {
                let result = evaluate(e, context: context)
                if case .number(let n) = result { return Int(n) }
            }
            return minVal
        }()
        let writeKey = writeBackKey(valueExpr)

        TextField("", value: Binding<Int>(
            get: { currentValue },
            set: { newVal in
                if let key = writeKey { commitPanelWrite(key: key, value: newVal) }
            }
        ), format: .number)
            .frame(width: 45)
            .textFieldStyle(.roundedBorder)
    }

    // MARK: - Text Input

    @ViewBuilder
    private func renderTextInput() -> some View {
        let placeholder = element["placeholder"] as? String ?? ""
        let bind = element["bind"] as? [String: Any]
        let valueExpr = bind?["value"] as? String
        let currentValue: String = {
            if let e = valueExpr {
                let result = evaluate(e, context: context)
                if case .string(let s) = result { return s }
            }
            return ""
        }()
        let writeKey = writeBackKey(valueExpr)

        TextField(placeholder, text: Binding<String>(
            get: { currentValue },
            set: { newVal in
                if let key = writeKey { commitPanelWrite(key: key, value: newVal) }
            }
        ))
            .textFieldStyle(.roundedBorder)
    }

    // MARK: - Color Swatch

    @ViewBuilder
    private func renderColorSwatch() -> some View {
        let size = (element["style"] as? [String: Any])?["size"] as? CGFloat ?? 16
        let hollow = element["hollow"] as? Bool ?? false

        let color: NSColor = {
            if let bind = element["bind"] as? [String: Any],
               let colorExpr = bind["color"] as? String {
                let result = evaluate(colorExpr, context: context)
                switch result {
                case .color(let c), .string(let c):
                    let (r, g, b) = parseHex(c)
                    return NSColor(
                        red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                        blue: CGFloat(b) / 255, alpha: 1
                    )
                default:
                    return .clear
                }
            }
            return .clear
        }()

        if hollow {
            Rectangle()
                .stroke(SwiftUI.Color(nsColor: color), lineWidth: 3)
                .frame(width: size, height: size)
        } else {
            Rectangle()
                .fill(SwiftUI.Color(nsColor: color))
                .frame(width: size, height: size)
                .border(SwiftUI.Color.gray, width: 1)
        }
    }

    // MARK: - Separator

    @ViewBuilder
    private func renderSeparator() -> some View {
        let orientation = element["orientation"] as? String ?? "horizontal"
        if orientation == "vertical" {
            Rectangle()
                .fill(SwiftUI.Color.gray.opacity(0.5))
                .frame(width: 1)
        } else {
            Rectangle()
                .fill(SwiftUI.Color.gray.opacity(0.5))
                .frame(height: 1)
        }
    }

    // MARK: - Disclosure

    @ViewBuilder
    private func renderDisclosure() -> some View {
        let label = element["label"] as? String ?? ""
        let labelText = label.contains("{{")
            ? evaluateText(label, context: context)
            : label

        DisclosureGroup(labelText) {
            renderChildElements()
        }
    }

    // MARK: - Panel

    @ViewBuilder
    private func renderPanel() -> some View {
        if let content = element["content"] as? [String: Any] {
            YamlElementView(element: content, context: context, model: model, panelId: panelId)
        } else {
            renderPlaceholder()
        }
    }

    // MARK: - Tree View

    @ViewBuilder
    private func renderTreeView() -> some View {
        if let model = model {
            TreeViewContent(model: model)
        } else {
            SwiftUI.Text("[Element hierarchy]")
                .foregroundColor(.gray)
                .frame(minHeight: 30)
        }
    }

    // MARK: - Element Preview

    @ViewBuilder
    private func renderElementPreview() -> some View {
        let sz = (element["style"] as? [String: Any])?["size"] as? Int ?? 32
        Rectangle()
            .fill(SwiftUI.Color.white)
            .overlay(Rectangle().stroke(SwiftUI.Color.gray, lineWidth: 1))
            .frame(width: CGFloat(sz), height: CGFloat(sz))
    }

    // MARK: - Placeholder

    @ViewBuilder
    private func renderPlaceholder() -> some View {
        let summary = element["summary"] as? String
            ?? element["type"] as? String
            ?? "?"
        SwiftUI.Text("[\(summary)]")
            .foregroundColor(.gray)
            .frame(minHeight: 30)
    }

    // MARK: - Select

    @ViewBuilder
    private func renderSelect() -> some View {
        let options = element["options"] as? [[String: Any]] ?? []
        let bind = element["bind"] as? [String: Any]
        let valueExpr = bind?["value"] as? String
        let currentValue: String = {
            if let e = valueExpr {
                let result = evaluate(e, context: context)
                if case .string(let s) = result { return s }
            }
            return ""
        }()
        let writeKey = writeBackKey(valueExpr)

        let entries = options.enumerated().map { i, opt -> PickerEntry in
            let v = opt["value"].map { "\($0)" } ?? ""
            let l = opt["label"] as? String ?? ""
            return PickerEntry(id: i, val: v, displayLabel: l.isEmpty ? v : l)
        }
        Picker("", selection: Binding<String>(
            get: { currentValue },
            set: { newVal in
                if let key = writeKey { commitPanelWrite(key: key, value: newVal) }
            }
        )) {
            ForEach(entries) { e in
                SwiftUI.Text(e.displayLabel).tag(e.val)
            }
        }
        .labelsHidden()
    }

    // MARK: - Toggle / Checkbox

    @ViewBuilder
    private func renderToggle() -> some View {
        let label = element["label"] as? String ?? ""
        let bind = element["bind"] as? [String: Any]
        let checkedExpr = bind?["checked"] as? String
        let isChecked: Bool = {
            if let e = checkedExpr {
                return evaluate(e, context: context).toBool()
            }
            return false
        }()
        let writeKey = writeBackKey(checkedExpr)

        Toggle(label, isOn: Binding<Bool>(
            get: { isChecked },
            set: { newVal in
                if let key = writeKey { commitPanelWrite(key: key, value: newVal) }
            }
        ))
            .toggleStyle(.checkbox)
    }

    // MARK: - Combo Box

    @ViewBuilder
    private func renderComboBox() -> some View {
        let options = element["options"] as? [[String: Any]] ?? []
        let bind = element["bind"] as? [String: Any]
        let valueExpr = bind?["value"] as? String
        let currentValue: String = {
            if let e = valueExpr {
                let result = evaluate(e, context: context)
                switch result {
                case .string(let s): return s
                case .number(let n): return String(Int(n))
                default: return ""
                }
            }
            return ""
        }()
        let writeKey = writeBackKey(valueExpr)

        // SwiftUI doesn't have a native combo box with free entry;
        // use Picker as a dropdown with the current value displayed.
        let entries = options.enumerated().map { i, opt -> PickerEntry in
            let v = opt["value"].map { "\($0)" } ?? ""
            let l = opt["label"] as? String ?? ""
            return PickerEntry(id: i, val: v, displayLabel: l.isEmpty ? v : l)
        }
        Picker("", selection: Binding<String>(
            get: { currentValue },
            set: { newVal in
                if let key = writeKey { commitPanelWrite(key: key, value: newVal) }
            }
        )) {
            ForEach(entries) { e in
                SwiftUI.Text(e.displayLabel).tag(e.val)
            }
        }
        .labelsHidden()
    }

    // MARK: - Children

    @ViewBuilder
    private func renderChildElements() -> some View {
        let children = element["children"] as? [[String: Any]] ?? []
        ForEach(0..<children.count, id: \.self) { i in
            YamlElementView(element: children[i], context: context, model: model, panelId: panelId)
        }
    }
}

/// A simple slider wrapper to avoid @State in the recursive view.
private struct SliderView: View {
    @State var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        Slider(value: $value, in: range)
    }
}

// MARK: - Tree View Content (live document)

private let layerColors = [
    "#4a90d9", "#d94a4a", "#4ad94a", "#4a4ad9", "#d9d94a",
    "#d94ad9", "#4ad9d9", "#b0b0b0", "#2a7a2a",
]

private func elementTypeLabel(_ elem: Element) -> String {
    switch elem {
    case .line: return "Line"
    case .rect: return "Rectangle"
    case .circle: return "Circle"
    case .ellipse: return "Ellipse"
    case .polyline: return "Polyline"
    case .polygon: return "Polygon"
    case .path: return "Path"
    case .text: return "Text"
    case .textPath: return "Text Path"
    case .group: return "Group"
    case .layer: return "Layer"
    }
}

private func elementDisplayName(_ elem: Element) -> (String, Bool) {
    if case .layer(let le) = elem, !le.name.isEmpty {
        return (le.name, true)
    }
    return ("<\(elementTypeLabel(elem))>", false)
}

private func visIcon(_ vis: Visibility) -> String {
    switch vis {
    case .preview: return "\u{25C9}"
    case .outline: return "\u{25D0}"
    case .invisible: return "\u{25CB}"
    }
}

private func pathToString(_ path: ElementPath) -> String {
    path.map(String.init).joined(separator: ",")
}

private func cycleVisibility(_ vis: Visibility) -> Visibility {
    switch vis {
    case .preview: return .outline
    case .outline: return .invisible
    case .invisible: return .preview
    }
}

/// Build a fitted-viewBox SVG fragment for a single element.
private func buildPreviewSvg(_ elem: Element) -> String {
    let b = elem.bounds
    let w = b.width, h = b.height
    if !w.isFinite || !h.isFinite || w <= 0 || h <= 0 {
        return ""
    }
    let pad = max(max(w, h) * 0.02, 0.5)
    let vb = "\(b.x - pad) \(b.y - pad) \(w + 2 * pad) \(h + 2 * pad)"
    let inner = elementSvg(elem, indent: "")
    return #"<svg xmlns="http://www.w3.org/2000/svg" viewBox=""# + vb + #"" preserveAspectRatio="xMidYMid meet">"# + inner + "</svg>"
}

/// SwiftUI view that renders an element as a fitted SVG thumbnail.
/// NSImage natively parses SVG data on recent macOS.
struct ElementThumbnail: View {
    let elem: Element
    let size: CGFloat

    var body: some View {
        let svg = buildPreviewSvg(elem)
        ZStack {
            Rectangle().fill(SwiftUI.Color.white)
            if let data = svg.data(using: .utf8),
               let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(1)
            }
        }
        .frame(width: size, height: size)
        .overlay(Rectangle().stroke(SwiftUI.Color.gray, lineWidth: 1))
    }
}

/// Wrapper that makes an ElementPath Identifiable for use with .sheet(item:).
struct IdentifiablePath: Identifiable {
    let id: String
    let path: ElementPath
}

/// Modal sheet for editing a layer's name, lock state, and visibility.
struct LayerOptionsSheet: View {
    @ObservedObject var model: Model
    let path: ElementPath
    let onClose: () -> Void

    @State private var name: String = ""
    @State private var lock: Bool = false
    @State private var show: Bool = true
    @State private var preview: Bool = true

    var body: some View {
        let e = model.document.getElement(path)
        VStack(alignment: .leading, spacing: 10) {
            SwiftUI.Text("Layer Options").font(.headline)
            HStack {
                SwiftUI.Text("Name:")
                TextField("", text: $name)
            }
            Toggle("Lock", isOn: $lock)
            Toggle("Show", isOn: $show)
            Toggle("Preview", isOn: $preview).disabled(!show)
            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                Button("OK") {
                    // Route through the YAML layer_options_confirm action
                    // so Swift shares the commit logic with the spec.
                    let layerIdStr = path.map(String.init)
                        .joined(separator: ".")
                    LayersPanel.dispatchYamlAction(
                        "layer_options_confirm",
                        model: model,
                        params: [
                            "layer_id": layerIdStr,
                            "name": name,
                            "lock": lock,
                            "show": show,
                            "preview": preview,
                        ],
                        onCloseDialog: onClose
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            if case .layer(let le) = e {
                name = le.name
                lock = le.locked
                show = le.visibility != .invisible
                preview = le.visibility == .preview
            }
        }
    }
}

/// Flat row descriptor used when rendering the tree. Pre-computing this
/// list lets us apply filters (search, type, isolation) without recursive
/// SwiftUI views.
struct FlatRow: Identifiable {
    let id: String
    let path: ElementPath
    let elem: Element
    let depth: Int
    let isContainer: Bool
    let isCollapsed: Bool
    let layerColor: String
}

struct TreeViewContent: View {
    @ObservedObject var model: Model
    @State private var collapsed: Set<ElementPath> = []
    @State private var panelSelection: Set<ElementPath> = []
    @State private var panelSelectionAnchor: ElementPath? = nil
    @State private var renamingPath: ElementPath? = nil
    @State private var editingName: String = ""
    @State private var dragSource: ElementPath? = nil
    @State private var dragTarget: ElementPath? = nil
    @State private var searchQuery: String = ""
    @State private var isolationStack: [ElementPath] = []
    @State private var soloState: (path: ElementPath, saved: [ElementPath: Visibility])? = nil
    @State private var savedLockStates: [ElementPath: [Bool]] = [:]
    @State private var hiddenTypes: Set<String> = []
    @State private var showLayerOptionsFor: ElementPath? = nil
    @State private var showFilterMenu: Bool = false
    @FocusState private var treeFocused: Bool
    // Tracks current modifier keys from an NSEvent monitor (macOS).
    @State private var modifierFlags: NSEvent.ModifierFlags = []

    private func elementChildrenStatic(_ elem: Element) -> [Element]? {
        switch elem {
        case .group(let g): return g.children
        case .layer(let l): return l.children
        default: return nil
        }
    }

    private func isContainerElem(_ elem: Element) -> Bool {
        switch elem {
        case .group, .layer: return true
        default: return false
        }
    }

    private func typeValue(_ elem: Element) -> String {
        switch elem {
        case .line: return "line"
        case .rect: return "rectangle"
        case .circle: return "circle"
        case .ellipse: return "ellipse"
        case .polyline: return "polyline"
        case .polygon: return "polygon"
        case .path: return "path"
        case .text: return "text"
        case .textPath: return "text_path"
        case .group: return "group"
        case .layer: return "layer"
        }
    }

    private func flatten(_ doc: Document) -> [FlatRow] {
        var out: [FlatRow] = []
        func walk(_ children: [Element], depth: Int, prefix: ElementPath, color: String) {
            for i in children.indices.reversed() {
                let elem = children[i]
                let path = prefix + [i]
                let isCont = isContainerElem(elem)
                let isColl = collapsed.contains(path)
                let myColor: String = {
                    if case .layer = elem, path.count == 1 {
                        return layerColors[i % layerColors.count]
                    }
                    return color
                }()
                let id = path.map(String.init).joined(separator: "_")
                out.append(FlatRow(id: id, path: path, elem: elem, depth: depth,
                                   isContainer: isCont, isCollapsed: isColl, layerColor: myColor))
                if isCont && !isColl, let kids = elementChildrenStatic(elem) {
                    walk(kids, depth: depth + 1, prefix: path, color: myColor)
                }
            }
        }
        // Top-level layers as Element.layer
        let topElements = doc.layers.map { Element.layer($0) }
        walk(topElements, depth: 0, prefix: [], color: "#4a90d9")
        return out
    }

    private func applyFilters(_ rows: [FlatRow]) -> [FlatRow] {
        var result = rows
        // Type filter
        if !hiddenTypes.isEmpty {
            let visible = Set(result.filter { !hiddenTypes.contains(typeValue($0.elem)) }.map { $0.path })
            var keep = visible
            for p in visible {
                for i in 1..<p.count { keep.insert(Array(p.prefix(i))) }
            }
            result = result.filter { keep.contains($0.path) }
        }
        // Isolation filter
        if let root = isolationStack.last {
            result = result.compactMap { r in
                guard r.path.count > root.count,
                      Array(r.path.prefix(root.count)) == root else { return nil }
                return FlatRow(id: r.id, path: r.path, elem: r.elem,
                               depth: r.depth - root.count,
                               isContainer: r.isContainer, isCollapsed: r.isCollapsed,
                               layerColor: r.layerColor)
            }
        }
        // Search filter
        let q = searchQuery.lowercased()
        if !q.isEmpty {
            let matching = Set(result.filter {
                let (n, _) = elementDisplayName($0.elem)
                return n.lowercased().contains(q)
            }.map { $0.path })
            var keep = matching
            for p in matching {
                for i in 1..<p.count { keep.insert(Array(p.prefix(i))) }
            }
            result = result.filter { keep.contains($0.path) }
        }
        return result
    }

    var body: some View {
        let doc = model.document
        let selectedPaths = doc.selectedPaths
        // Auto-expand ancestors of selected paths
        for p in selectedPaths where p.count > 1 {
            for i in 1..<p.count {
                let anc = Array(p.prefix(i))
                if collapsed.contains(anc) {
                    // Note: mutating @State during body is discouraged; use a
                    // DispatchQueue hop to defer the change
                    DispatchQueue.main.async {
                        collapsed.remove(anc)
                    }
                }
            }
        }
        let rows = applyFilters(flatten(doc))
        let firstSelected = selectedPaths.sorted(by: { $0.lexicographicallyPrecedes($1) }).first
        return VStack(spacing: 0) {
            // Search/filter bar
            HStack(spacing: 4) {
                TextField("Search...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 4)
                Menu {
                    let types: [(String, String)] = [
                        ("Layer", "layer"), ("Group", "group"),
                        ("Path", "path"), ("Rectangle", "rectangle"),
                        ("Circle", "circle"), ("Ellipse", "ellipse"),
                        ("Polyline", "polyline"), ("Polygon", "polygon"),
                        ("Text", "text"), ("Text Path", "text_path"),
                        ("Line", "line"),
                    ]
                    ForEach(types, id: \.1) { (label, value) in
                        Button(action: {
                            if hiddenTypes.contains(value) { hiddenTypes.remove(value) }
                            else { hiddenTypes.insert(value) }
                        }) {
                            if hiddenTypes.contains(value) {
                                SwiftUI.Text(label)
                            } else {
                                SwiftUI.Text("✓ \(label)")
                            }
                        }
                    }
                } label: {
                    SwiftUI.Text("▾").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(SwiftUI.Color(white: 0.14))

            if !isolationStack.isEmpty {
                breadcrumbBar
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row: row, selectedPaths: selectedPaths)
                                .id(row.id)
                        }
                    }
                }
                .onChange(of: firstSelected) { newVal in
                    if let p = newVal {
                        let rowId = p.map(String.init).joined(separator: "_")
                        withAnimation { proxy.scrollTo(rowId, anchor: .center) }
                    }
                }
            }
        }
        .focusable()
        .focused($treeFocused)
        .onAppear {
            // NSEvent local monitor to capture modifier keys during mouse events.
            // Also handles Delete/Cmd-A/Escape key shortcuts when the tree is focused.
            NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .leftMouseDown, .keyDown]) { evt in
                modifierFlags = evt.modifierFlags
                if evt.type == .keyDown && treeFocused {
                    if evt.keyCode == 51 || evt.keyCode == 117 {
                        // 51 = Delete (backspace), 117 = Forward Delete
                        performDeleteSelection()
                        return nil
                    } else if evt.keyCode == 0 && evt.modifierFlags.contains(.command) {
                        // 0 = 'a' — Cmd-A selects all
                        selectAll()
                        return nil
                    } else if evt.keyCode == 53 {
                        // 53 = Escape
                        if renamingPath != nil { renamingPath = nil; return nil }
                        if !isolationStack.isEmpty { isolationStack.removeLast(); return nil }
                    }
                }
                return evt
            }
        }
        .sheet(item: Binding<IdentifiablePath?>(
            get: { showLayerOptionsFor.map { IdentifiablePath(id: $0.map(String.init).joined(separator: "_"), path: $0) } },
            set: { showLayerOptionsFor = $0?.path }
        )) { ip in
            LayerOptionsSheet(model: model, path: ip.path, onClose: { showLayerOptionsFor = nil })
        }
    }

    private func performDrop(onto target: ElementPath) -> Bool {
        guard let src = dragSource, src != target else {
            dragSource = nil; dragTarget = nil
            return false
        }
        // Constraints
        let isCycle = target.count >= src.count && Array(target.prefix(src.count)) == src
        let parentPath = Array(target.dropLast())
        var parentLocked = false
        if !parentPath.isEmpty {
            parentLocked = model.document.getElement(parentPath).isLocked
        }
        if isCycle || parentLocked {
            dragSource = nil; dragTarget = nil
            return false
        }
        let moved = model.document.getElement(src)
        model.snapshot()
        var doc = model.document.deleteElement(src)
        var tgt = target
        let sameLevel = (src.count == tgt.count) && (Array(src.dropLast()) == Array(tgt.dropLast()))
        let srcLast = src.last ?? 0
        let tgtLast = tgt.last ?? 0
        if sameLevel && srcLast < tgtLast {
            tgt[tgt.count - 1] = tgtLast - 1
        }
        let tl = tgt.last ?? 0
        if tl > 0 {
            var insertAfter = tgt
            insertAfter[insertAfter.count - 1] = tl - 1
            doc = doc.insertElementAfter(insertAfter, element: moved)
        } else {
            doc = doc.insertElementAfter(tgt, element: moved)
        }
        model.document = doc
        dragSource = nil; dragTarget = nil
        return true
    }

    private func handleRowTap(path: ElementPath) {
        let shift = modifierFlags.contains(.shift)
        let cmd = modifierFlags.contains(.command)
        if shift, let anchor = panelSelectionAnchor {
            // Range selection in visual order (flat row list).
            let rows = applyFilters(flatten(model.document))
            let allPaths = rows.map { $0.path }
            if let a = allPaths.firstIndex(of: anchor),
               let c = allPaths.firstIndex(of: path) {
                let (lo, hi) = a <= c ? (a, c) : (c, a)
                panelSelection = Set(allPaths[lo...hi])
            } else {
                panelSelection = [path]
            }
        } else if cmd {
            if panelSelection.contains(path) { panelSelection.remove(path) }
            else { panelSelection.insert(path) }
            panelSelectionAnchor = path
        } else {
            panelSelection = [path]
            panelSelectionAnchor = path
        }
    }

    private func handleEyeTap(path: ElementPath) {
        let opt = modifierFlags.contains(.option)
        let e = model.document.getElement(path)
        if opt {
            // Option-click: solo/unsolo among siblings
            let parentPrefix = Array(path.dropLast())
            let siblings: [ElementPath] = {
                if parentPrefix.isEmpty {
                    return (0..<model.document.layers.count).map { [$0] }
                }
                let parent = model.document.getElement(parentPrefix)
                let kids: [Element]
                switch parent {
                case .group(let g): kids = g.children
                case .layer(let l): kids = l.children
                default: return []
                }
                return (0..<kids.count).map { parentPrefix + [$0] }
            }()
            if let s = soloState, s.path == path {
                // Unsolo: restore
                model.snapshot()
                var d = model.document
                for (sp, vis) in s.saved {
                    let e2 = d.getElement(sp)
                    d = d.replaceElement(sp, with: e2.withVisibility(vis))
                }
                model.document = d
                soloState = nil
            } else {
                var saved: [ElementPath: Visibility] = [:]
                for sp in siblings where sp != path {
                    saved[sp] = model.document.getElement(sp).visibility
                }
                model.snapshot()
                var d = model.document
                if e.visibility == .invisible {
                    d = d.replaceElement(path, with: e.withVisibility(.preview))
                }
                for sp in siblings where sp != path {
                    let e2 = d.getElement(sp)
                    d = d.replaceElement(sp, with: e2.withVisibility(.invisible))
                }
                model.document = d
                soloState = (path: path, saved: saved)
            }
        } else {
            soloState = nil
            let newVis = cycleVisibility(e.visibility)
            model.snapshot()
            model.document = model.document.replaceElement(path, with: e.withVisibility(newVis))
        }
    }

    private func performDeleteSelection() {
        guard !panelSelection.isEmpty else { return }
        let topDeletes = panelSelection.filter { $0.count == 1 }.count
        if topDeletes >= model.document.layers.count { return }
        LayersPanel.dispatchYamlAction(
            "delete_layer_selection",
            model: model,
            panelSelection: panelSelection.map { Array($0) }
        )
        panelSelection.removeAll()
    }

    private func selectAll() {
        panelSelection.removeAll()
        func collect(_ children: [Element], prefix: ElementPath) {
            for (i, e) in children.enumerated() {
                let p = prefix + [i]
                panelSelection.insert(p)
                switch e {
                case .group(let g): collect(g.children, prefix: p)
                case .layer(let l): collect(l.children, prefix: p)
                default: break
                }
            }
        }
        let tops = model.document.layers.map { Element.layer($0) }
        collect(tops, prefix: [])
    }

    @ViewBuilder
    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            SwiftUI.Text("⌂")
                .font(.system(size: 11))
                .onTapGesture { isolationStack.removeAll() }
            ForEach(Array(isolationStack.enumerated()), id: \.offset) { idx, p in
                SwiftUI.Text(">")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                let label: String = {
                    let e = model.document.getElement(p)
                    let (n, _) = elementDisplayName(e)
                    return n
                }()
                SwiftUI.Text(label)
                    .font(.system(size: 11))
                    .onTapGesture { isolationStack = Array(isolationStack.prefix(idx + 1)) }
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(SwiftUI.Color(white: 0.16))
    }

    @ViewBuilder
    private func rowView(row: FlatRow, selectedPaths: Set<ElementPath>) -> some View {
        let elem = row.elem
        let path = row.path
        let isSelected = selectedPaths.contains(path)
        let isPanelSelected = panelSelection.contains(path)
        let (name, isNamed) = elementDisplayName(elem)
        let vis = elem.visibility
        let locked = elem.isLocked
        HStack(spacing: 2) {
            if row.depth > 0 {
                Spacer().frame(width: CGFloat(row.depth * 16))
            }
            // Eye — supports Option-click for solo/unsolo
            SwiftUI.Text(visIcon(vis))
                .frame(width: 16, height: 16)
                .onTapGesture { handleEyeTap(path: path) }
            // Lock
            SwiftUI.Text(locked ? "\u{1F512}" : "\u{1F513}")
                .frame(width: 16, height: 16)
                .onTapGesture {
                    let e = model.document.getElement(path)
                    let wasUnlocked = !e.isLocked
                    let isCont = isContainerElem(e)
                    model.snapshot()
                    var doc = model.document
                    // Save child states when locking a container
                    if isCont && wasUnlocked, let kids = elementChildrenStatic(e) {
                        savedLockStates[path] = kids.map { $0.isLocked }
                    }
                    doc = doc.replaceElement(path, with: e.withLocked(wasUnlocked))
                    // Lock all children when container locked
                    if isCont && wasUnlocked, let kids = elementChildrenStatic(e) {
                        for (i, c) in kids.enumerated() {
                            let cp = path + [i]
                            doc = doc.replaceElement(cp, with: c.withLocked(true))
                        }
                    }
                    // Restore children on unlock
                    if isCont && !wasUnlocked, let saved = savedLockStates.removeValue(forKey: path) {
                        let e2 = doc.getElement(path)
                        if let kids2 = elementChildrenStatic(e2) {
                            for (i, c) in kids2.enumerated() where i < saved.count {
                                let cp = path + [i]
                                doc = doc.replaceElement(cp, with: c.withLocked(saved[i]))
                            }
                        }
                    }
                    model.document = doc
                }
            // Twirl or gap
            if row.isContainer {
                let isColl = collapsed.contains(path)
                SwiftUI.Text(isColl ? "\u{25B6}" : "\u{25BC}")
                    .frame(width: 16, height: 16)
                    .onTapGesture {
                        if collapsed.contains(path) { collapsed.remove(path) }
                        else { collapsed.insert(path) }
                    }
            } else {
                Spacer().frame(width: 16)
            }
            // Preview thumbnail
            ElementThumbnail(elem: elem, size: 24)
            // Name — inline TextField when renaming, Text otherwise
            if renamingPath == path {
                TextField("", text: $editingName, onCommit: {
                    let e = model.document.getElement(path)
                    if case .layer(let le) = e {
                        let newLayer = Layer(name: editingName, children: le.children,
                                             opacity: le.opacity, transform: le.transform,
                                             locked: le.locked, visibility: le.visibility)
                        model.snapshot()
                        model.document = model.document.replaceElement(path, with: .layer(newLayer))
                    }
                    renamingPath = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .onExitCommand { renamingPath = nil }
            } else {
                SwiftUI.Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(isNamed ? SwiftUI.Color.white : SwiftUI.Color.gray)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) {
                        if case .layer(let le) = elem {
                            editingName = le.name
                            renamingPath = path
                        }
                    }
            }
            // Select square
            Rectangle()
                .fill(isSelected ? SwiftUI.Color.blue : SwiftUI.Color.clear)
                .overlay(Rectangle().stroke(SwiftUI.Color.gray, lineWidth: 1))
                .frame(width: 12, height: 12)
                .onTapGesture {
                    model.document = Document(
                        layers: model.document.layers,
                        selectedLayer: model.document.selectedLayer,
                        selection: [ElementSelection.all(path)]
                    )
                }
        }
        .frame(height: 24)
        .padding(.horizontal, 4)
        .background(isPanelSelected ? SwiftUI.Color.blue.opacity(0.3) : SwiftUI.Color.clear)
        .overlay(
            dragTarget == path && dragSource != nil && dragSource != path
                ? Rectangle().fill(SwiftUI.Color.blue).frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: .top)
                : nil
        )
        .contentShape(Rectangle())
        .onTapGesture {
            handleRowTap(path: path)
        }
        .contextMenu {
            if case .layer = elem {
                Button("Options for Layer...") { showLayerOptionsFor = path }
            } else {
                Button("Options for Layer...") {}.disabled(true)
            }
            Button("Duplicate") { duplicateSelection() }
            Button("Delete Selection") { deleteSelection() }
            Divider()
            if isolationStack.isEmpty {
                Button("Enter Isolation Mode") { isolationStack.append(path) }
                    .disabled(!row.isContainer)
            } else {
                Button("Exit Isolation Mode") { isolationStack.removeLast() }
            }
            Divider()
            Button("Flatten Artwork") { flattenArtwork() }
            Button("Collect in New Layer") { collectInNewLayer() }
        }
        .onDrag {
            dragSource = path
            return NSItemProvider(object: pathToString(path) as NSString)
        }
        .onDrop(of: ["public.text"], isTargeted: Binding(
            get: { dragTarget == path },
            set: { isOver in
                if isOver && dragSource != nil && dragSource != path {
                    dragTarget = path
                    // Auto-expand collapsed containers after 500ms hover
                    let isCont = row.isContainer
                    let isColl = row.isCollapsed
                    if isCont && isColl {
                        let p = path
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let still = (dragTarget == p) && (dragSource != nil)
                            if still {
                                collapsed.remove(p)
                            }
                        }
                    }
                } else if !isOver && dragTarget == path {
                    dragTarget = nil
                }
            }
        )) { _ in
            return performDrop(onto: path)
        }
    }

    // MARK: - Context menu actions

    private func deleteSelection() {
        guard !panelSelection.isEmpty else { return }
        let topDeletes = panelSelection.filter { $0.count == 1 }.count
        if topDeletes >= model.document.layers.count { return }
        LayersPanel.dispatchYamlAction(
            "delete_layer_selection",
            model: model,
            panelSelection: panelSelection.map { Array($0) }
        )
        panelSelection.removeAll()
    }

    private func duplicateSelection() {
        guard !panelSelection.isEmpty else { return }
        LayersPanel.dispatchYamlAction(
            "duplicate_layer_selection",
            model: model,
            panelSelection: panelSelection.map { Array($0) }
        )
    }

    private func flattenArtwork() {
        guard !panelSelection.isEmpty else { return }
        model.snapshot()
        var d = model.document
        for p in panelSelection.sorted(by: { $0.lexicographicallyPrecedes($1) }).reversed() {
            let e = d.getElement(p)
            if case .group(let g) = e {
                d = d.deleteElement(p)
                var insertPath = p
                var firstInsert = true
                for child in g.children {
                    if firstInsert && (insertPath.last ?? 0) == 0 {
                        d = d.insertElementAfter(insertPath, element: child)
                    } else if firstInsert {
                        var ia = insertPath
                        ia[ia.count - 1] = (ia.last ?? 1) - 1
                        d = d.insertElementAfter(ia, element: child)
                    } else {
                        d = d.insertElementAfter(insertPath, element: child)
                    }
                    firstInsert = false
                    insertPath[insertPath.count - 1] += 1
                }
            }
        }
        model.document = d
        panelSelection.removeAll()
    }

    private func collectInNewLayer() {
        guard !panelSelection.isEmpty else { return }
        LayersPanel.dispatchYamlAction(
            "collect_in_new_layer",
            model: model,
            panelSelection: panelSelection.map { Array($0) }
        )
        panelSelection.removeAll()
    }

    @available(*, deprecated, message: "unused, kept as stub")
    @ViewBuilder
    private func treeRows_DEPRECATED() -> some View {
        EmptyView()
    }

    /* OLD BODY REMOVED:
    private func treeRows_OLD(elem: Element, path: ElementPath, depth: Int, layerColor: String, selectedPaths: Set<ElementPath>) -> some View {
        let isSelected = selectedPaths.contains(path)
        let isPanelSelected = panelSelection.contains(path)
        let (name, isNamed) = elementDisplayName(elem)
        let vis = elem.visibility
        let locked = elem.isLocked

        HStack(spacing: 2) {
            // Indent
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth * 16))
            }
            // Eye
            SwiftUI.Text(visIcon(vis))
                .frame(width: 16, height: 16)
                .onTapGesture {
                    let e = model.document.getElement(path)
                    let newE = e.withVisibility(cycleVisibility(e.visibility))
                    model.snapshot()
                    model.document = model.document.replaceElement(path, with: newE)
                }
            // Lock
            SwiftUI.Text(locked ? "\u{1F512}" : "\u{1F513}")
                .frame(width: 16, height: 16)
                .onTapGesture {
                    let e = model.document.getElement(path)
                    let newE = e.withLocked(!e.isLocked)
                    model.snapshot()
                    model.document = model.document.replaceElement(path, with: newE)
                }
            // Twirl or gap
            if isContainer(elem) {
                let isCollapsed = collapsed.contains(path)
                SwiftUI.Text(isCollapsed ? "\u{25B6}" : "\u{25BC}")
                    .frame(width: 16, height: 16)
                    .onTapGesture {
                        if collapsed.contains(path) {
                            collapsed.remove(path)
                        } else {
                            collapsed.insert(path)
                        }
                    }
            } else {
                Spacer().frame(width: 16)
            }
            // Preview — fitted-viewBox SVG thumbnail of the element
            ElementThumbnail(elem: elem, size: 24)
            // Name — inline TextField when renaming, Text otherwise
            if renamingPath == path {
                TextField("", text: $editingName, onCommit: {
                    let e = model.document.getElement(path)
                    if case .layer(let le) = e {
                        let newLayer = Layer(name: editingName, children: le.children,
                                             opacity: le.opacity, transform: le.transform,
                                             locked: le.locked, visibility: le.visibility)
                        model.snapshot()
                        model.document = model.document.replaceElement(path, with: .layer(newLayer))
                    }
                    renamingPath = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .onExitCommand {
                    renamingPath = nil
                }
            } else {
                SwiftUI.Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(isNamed ? SwiftUI.Color.white : SwiftUI.Color.gray)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) {
                        if case .layer(let le) = elem {
                            editingName = le.name
                            renamingPath = path
                        }
                    }
            }
            // Select square
            Rectangle()
                .fill(isSelected ? SwiftUI.Color.blue : SwiftUI.Color.clear)
                .overlay(Rectangle().stroke(SwiftUI.Color.gray, lineWidth: 1))
                .frame(width: 12, height: 12)
                .onTapGesture {
                    model.document = Document(
                        layers: model.document.layers,
                        selectedLayer: model.document.selectedLayer,
                        selection: [ElementSelection.all(path)]
                    )
                }
        }
        .frame(height: 24)
        .padding(.horizontal, 4)
        .background(isPanelSelected ? SwiftUI.Color.blue.opacity(0.3) : SwiftUI.Color.clear)
        .overlay(
            dragTarget == path && dragSource != nil && dragSource != path
                ? Rectangle().fill(SwiftUI.Color.blue).frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: .top)
                : nil
        )
        .contentShape(Rectangle())
        .onTapGesture {
            panelSelection = [path]
        }
        .onDrag {
            dragSource = path
            return NSItemProvider(object: pathToString(path) as NSString)
        }
        .onDrop(of: ["public.text"], isTargeted: Binding(
            get: { dragTarget == path },
            set: { isOver in
                if isOver && dragSource != nil && dragSource != path {
                    dragTarget = path
                } else if !isOver && dragTarget == path {
                    dragTarget = nil
                }
            }
        )) { providers in
            guard let src = dragSource, src != path else {
                dragSource = nil; dragTarget = nil
                return false
            }
            let moved = model.document.getElement(src)
            model.snapshot()
            var doc = model.document.deleteElement(src)
            // Adjust target if src was at same level and before
            var target = path
            if src.count == target.count, Array(src.dropLast()) == Array(target.dropLast()),
               let sl = src.last, let tl = target.last, sl < tl {
                target[target.count - 1] = tl - 1
            }
            // Insert before target: use insertElementAfter at target-1 or prepend
            if let tl = target.last, tl > 0 {
                var insertAfter = target
                insertAfter[insertAfter.count - 1] = tl - 1
                doc = doc.insertElementAfter(insertAfter, element: moved)
            } else {
                doc = doc.insertElementAfter(target, element: moved)
            }
            model.document = doc
            dragSource = nil; dragTarget = nil
            return true
        }

        // Children (reversed) — skip if collapsed
        if !collapsed.contains(path), let children = elementChildren(elem) {
            ForEach(Array(children.indices.reversed()), id: \.self) { ci in
                let child = children[ci]
                let childPath = path + [ci]
                treeRows(elem: child, path: childPath, depth: depth + 1, layerColor: layerColor, selectedPaths: selectedPaths)
            }
        }
    }
    */
}

/// Top-level view that renders a panel's YAML content.
struct YamlPanelBodyView: View {
    let contentSpec: [String: Any]
    let context: [String: Any]
    var model: Model?
    /// ID of the panel whose scope is active in `context["panel"]`.
    /// Widget write-backs inside this body route to
    /// `model.stateStore.setPanel(panelId, ...)`.
    var panelId: String?

    var body: some View {
        YamlElementView(element: contentSpec, context: context, model: model, panelId: panelId)
            .padding(4)
    }
}
