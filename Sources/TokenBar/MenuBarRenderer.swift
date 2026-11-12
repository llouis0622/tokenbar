import AppKit

struct BarCell: Equatable {
    let label: String
    let value: String
    let widest: String
}

enum BarColumn: Equatable {
    case cells([BarCell])
    case icon(symbol: String, values: [String], widest: String)
}

enum MenuBarRenderer {
    private static let labelFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let height: CGFloat = 22
    private static let rowHeight: CGFloat = 11
    private static let innerGap: CGFloat = 3
    private static let columnGap: CGFloat = 8
    private static let iconSize: CGFloat = 13

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func widths(_ column: BarColumn) -> (label: CGFloat, value: CGFloat) {
        switch column {
        case .cells(let cells):
            let label = cells.map { width($0.label, labelFont) }.max() ?? 0
            let value = cells.map { max(width($0.widest, valueFont), width($0.value, valueFont)) }.max() ?? 0
            return (label, value)
        case .icon(_, let values, let widest):
            let value = values.map { width($0, valueFont) }.max() ?? 0
            return (iconSize, max(value, width(widest, valueFont)))
        }
    }

    static func image(columns: [BarColumn]) -> NSImage {
        let measured = columns.map(widths)
        var total = columnGap * CGFloat(max(columns.count - 1, 0))
        for item in measured {
            total += item.label + innerGap + item.value
        }
        let image = NSImage(size: NSSize(width: max(total, 1), height: height), flipped: false) { _ in
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: NSColor.black.withAlphaComponent(0.6),
            ]
            let valueAttributes: [NSAttributedString.Key: Any] = [
                .font: valueFont,
                .foregroundColor: NSColor.black,
            ]
            var x: CGFloat = 0
            for (index, column) in columns.enumerated() {
                let valueRight = x + measured[index].label + innerGap + measured[index].value
                switch column {
                case .cells(let cells):
                    for (row, cell) in cells.enumerated() {
                        let y = height - rowHeight * CGFloat(row + 1)
                        (cell.label as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: labelAttributes)
                        let valueWidth = width(cell.value, valueFont)
                        (cell.value as NSString).draw(at: NSPoint(x: valueRight - valueWidth, y: y), withAttributes: valueAttributes)
                    }
                case .icon(let symbol, let values, _):
                    let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                    if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                        let scale = min(iconSize / max(glyph.size.width, 1), iconSize / max(glyph.size.height, 1), 1)
                        let size = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
                        let origin = NSPoint(x: x + (iconSize - size.width) / 2, y: (height - size.height) / 2)
                        glyph.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 0.75)
                    }
                    let shown = Array(values.prefix(2))
                    let top = height - (height - rowHeight * CGFloat(shown.count)) / 2
                    for (row, value) in shown.enumerated() {
                        let y = top - rowHeight * CGFloat(row + 1)
                        let valueWidth = width(value, valueFont)
                        (value as NSString).draw(at: NSPoint(x: valueRight - valueWidth, y: y), withAttributes: valueAttributes)
                    }
                }
                x = valueRight + columnGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
