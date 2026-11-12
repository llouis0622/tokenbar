import AppKit

struct BarCell: Equatable {
    let label: String
    let value: String
    let widest: String
}

enum MenuBarRenderer {
    private static let labelFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let height: CGFloat = 22
    private static let rowHeight: CGFloat = 11
    private static let innerGap: CGFloat = 3
    private static let columnGap: CGFloat = 8

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func image(columns: [[BarCell]]) -> NSImage {
        let labelWidths = columns.map { column in column.map { width($0.label, labelFont) }.max() ?? 0 }
        let valueWidths = columns.map { column in column.map { max(width($0.widest, valueFont), width($0.value, valueFont)) }.max() ?? 0 }
        var total: CGFloat = 0
        for index in columns.indices {
            total += labelWidths[index] + innerGap + valueWidths[index]
        }
        total += columnGap * CGFloat(max(columns.count - 1, 0))
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
                let valueRight = x + labelWidths[index] + innerGap + valueWidths[index]
                for (row, cell) in column.enumerated() {
                    let y = height - rowHeight * CGFloat(row + 1)
                    (cell.label as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: labelAttributes)
                    let valueWidth = width(cell.value, valueFont)
                    (cell.value as NSString).draw(at: NSPoint(x: valueRight - valueWidth, y: y), withAttributes: valueAttributes)
                }
                x = valueRight + columnGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
