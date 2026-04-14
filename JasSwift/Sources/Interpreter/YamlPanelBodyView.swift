/// SwiftUI view that renders a panel body from its YAML content spec.
///
/// Maps YAML element types to SwiftUI views: container → VStack/HStack,
/// text → Text, slider → Slider, color_swatch → colored Rectangle, etc.

import SwiftUI

/// Renders a YAML element tree as a SwiftUI view.
struct YamlElementView: View {
    let element: [String: Any]
    let context: [String: Any]

    var body: some View {
        // Check bind.visible — if the expression evaluates to false, hide the element.
        if !isVisible() {
            EmptyView()
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
                YamlElementView(element: children[i], context: context)
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
            YamlElementView(element: content, context: context)
        } else {
            renderPlaceholder()
        }
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

    // MARK: - Children

    @ViewBuilder
    private func renderChildElements() -> some View {
        let children = element["children"] as? [[String: Any]] ?? []
        ForEach(0..<children.count, id: \.self) { i in
            YamlElementView(element: children[i], context: context)
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

/// Top-level view that renders a panel's YAML content.
struct YamlPanelBodyView: View {
    let contentSpec: [String: Any]
    let context: [String: Any]

    var body: some View {
        YamlElementView(element: contentSpec, context: context)
            .padding(4)
    }
}
