/// SwiftUI view that renders a panel body from its YAML content spec.
///
/// Maps YAML element types to SwiftUI views: container → VStack/HStack,
/// text → Text, slider → Slider, color_swatch → colored Rectangle, etc.

import SwiftUI
import AppKit

/// Renders a YAML element tree as a SwiftUI view.
struct YamlElementView: View {
    let element: [String: Any]
    let context: [String: Any]
    var model: Model?

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
                    YamlElementView(element: template, context: childScope.toDict(), model: model)
                }
            }
        } else if layout == "row" {
            HStack(spacing: gap) {
                ForEach(0..<items.count, id: \.self) { i in
                    let childScope = scope.extend(itemBindings(varName, item: items[i], index: i))
                    YamlElementView(element: template, context: childScope.toDict(), model: model)
                }
            }
        } else {
            VStack(spacing: gap) {
                ForEach(0..<items.count, id: \.self) { i in
                    let childScope = scope.extend(itemBindings(varName, item: items[i], index: i))
                    YamlElementView(element: template, context: childScope.toDict(), model: model)
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
                YamlElementView(element: children[i], context: context, model: model)
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
        let maxVal = element["max"] as? Int ?? 100
        let initialValue: Int = {
            if let bind = element["bind"] as? [String: Any],
               let valueExpr = bind["value"] as? String {
                let result = evaluate(valueExpr, context: context)
                if case .number(let n) = result { return Int(n) }
            }
            return minVal
        }()

        TextField("", value: .constant(initialValue), format: .number)
            .frame(width: 45)
            .textFieldStyle(.roundedBorder)
    }

    // MARK: - Text Input

    @ViewBuilder
    private func renderTextInput() -> some View {
        let placeholder = element["placeholder"] as? String ?? ""
        TextField(placeholder, text: .constant(""))
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
            YamlElementView(element: content, context: context, model: model)
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
        let currentValue: String = {
            if let bind = element["bind"] as? [String: Any],
               let valueExpr = bind["value"] as? String {
                let result = evaluate(valueExpr, context: context)
                if case .string(let s) = result { return s }
            }
            return ""
        }()

        Picker("", selection: .constant(currentValue)) {
            ForEach(Array(options.enumerated()), id: \.offset) { item in
                let val = item.element["value"].map { "\($0)" } ?? ""
                let label = item.element["label"] as? String ?? val
                Text(label).tag(val)
            }
        }
        .labelsHidden()
    }

    // MARK: - Toggle / Checkbox

    @ViewBuilder
    private func renderToggle() -> some View {
        let label = element["label"] as? String ?? ""
        let isChecked: Bool = {
            if let bind = element["bind"] as? [String: Any],
               let checkedExpr = bind["checked"] as? String {
                return evaluate(checkedExpr, context: context).toBool()
            }
            return false
        }()

        Toggle(label, isOn: .constant(isChecked))
            .toggleStyle(.checkbox)
    }

    // MARK: - Combo Box

    @ViewBuilder
    private func renderComboBox() -> some View {
        let options = element["options"] as? [[String: Any]] ?? []
        let currentValue: String = {
            if let bind = element["bind"] as? [String: Any],
               let valueExpr = bind["value"] as? String {
                let result = evaluate(valueExpr, context: context)
                switch result {
                case .string(let s): return s
                case .number(let n): return String(Int(n))
                default: return ""
                }
            }
            return ""
        }()

        // SwiftUI doesn't have a native combo box with free entry;
        // use Picker as a dropdown with the current value displayed.
        Picker("", selection: .constant(currentValue)) {
            ForEach(Array(options.enumerated()), id: \.offset) { item in
                let val = item.element["value"].map { "\($0)" } ?? ""
                let label = item.element["label"] as? String ?? val
                Text(label).tag(val)
            }
        }
        .labelsHidden()
    }

    // MARK: - Children

    @ViewBuilder
    private func renderChildElements() -> some View {
        let children = element["children"] as? [[String: Any]] ?? []
        ForEach(0..<children.count, id: \.self) { i in
            YamlElementView(element: children[i], context: context, model: model)
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

struct TreeViewContent: View {
    @ObservedObject var model: Model
    @State private var collapsed: Set<ElementPath> = []
    @State private var panelSelection: Set<ElementPath> = []
    @State private var renamingPath: ElementPath? = nil
    @State private var editingName: String = ""
    @State private var dragSource: ElementPath? = nil
    @State private var dragTarget: ElementPath? = nil

    var body: some View {
        let doc = model.document
        let selectedPaths = doc.selectedPaths
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(doc.layers.indices.reversed()), id: \.self) { i in
                    let layer = doc.layers[i]
                    let elem = Element.layer(layer)
                    let path: ElementPath = [i]
                    let color = layerColors[i % layerColors.count]
                    treeRows(elem: elem, path: path, depth: 0, layerColor: color, selectedPaths: selectedPaths)
                }
            }
        }
    }

    private func elementChildren(_ elem: Element) -> [Element]? {
        switch elem {
        case .group(let g): return g.children
        case .layer(let l): return l.children
        default: return nil
        }
    }

    private func isContainer(_ elem: Element) -> Bool {
        switch elem {
        case .group, .layer: return true
        default: return false
        }
    }

    @ViewBuilder
    private func treeRows(elem: Element, path: ElementPath, depth: Int, layerColor: String, selectedPaths: Set<ElementPath>) -> some View {
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
}

/// Top-level view that renders a panel's YAML content.
struct YamlPanelBodyView: View {
    let contentSpec: [String: Any]
    let context: [String: Any]
    var model: Model?

    var body: some View {
        YamlElementView(element: contentSpec, context: context, model: model)
            .padding(4)
    }
}
