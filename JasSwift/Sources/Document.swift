import Foundation

/// A document consisting of a title and an ordered list of layers.
public struct JasDocument: Equatable {
    public let title: String
    public let layers: [JasLayer]

    public init(title: String = "Untitled", layers: [JasLayer] = []) {
        self.title = title
        self.layers = layers
    }

    public var bounds: BBox {
        guard !layers.isEmpty else { return (0, 0, 0, 0) }
        let all = layers.map(\.bounds)
        let minX = all.map(\.x).min()!, minY = all.map(\.y).min()!
        let maxX = all.map { $0.x + $0.width }.max()!
        let maxY = all.map { $0.y + $0.height }.max()!
        return (minX, minY, maxX - minX, maxY - minY)
    }
}
