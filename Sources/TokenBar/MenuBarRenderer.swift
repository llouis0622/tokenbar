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

    static func bitmap(_ image: NSImage, scale: CGFloat) -> NSBitmapImageRep? {
        let size = image.size
        let pixelsWide = Int((size.width * scale).rounded(.up))
        let pixelsHigh = Int((size.height * scale).rounded(.up))
        guard pixelsWide >= 1, pixelsHigh >= 1,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: pixelsWide,
                  pixelsHigh: pixelsHigh,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              )
        else { return nil }
        bitmap.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let wanted = CGFloat(pixelsWide) / size.width
        let applied = abs(context.cgContext.ctm.a)
        if applied > 0, abs(applied - wanted) > 0.01 {
            context.cgContext.scaleBy(x: wanted / applied, y: wanted / applied)
        }
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    static func rasterize(_ image: NSImage, scale: CGFloat) -> NSImage {
        guard let bitmap = bitmap(image, scale: scale) else { return image }
        let result = NSImage(size: image.size)
        result.addRepresentation(bitmap)
        return result
    }

    static func coverage(_ bitmap: NSBitmapImageRep) -> (width: Double, height: Double) {
        var minX = bitmap.pixelsWide, maxX = -1, minY = bitmap.pixelsHigh, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.2 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return (0, 0) }
        return (Double(maxX - minX + 1) / Double(bitmap.pixelsWide), Double(maxY - minY + 1) / Double(bitmap.pixelsHigh))
    }

    static func compose(leading: NSImage?, stats: NSImage) -> NSImage {
        guard let leading else {
            stats.isTemplate = true
            return stats
        }
        let offset = leading.size.width + columnGap - 2
        let size = NSSize(width: offset + stats.size.width, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            leading.draw(in: NSRect(origin: .zero, size: leading.size))
            stats.draw(in: NSRect(x: offset, y: 0, width: stats.size.width, height: stats.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum SlimeRenderer {
    static let frameCount = 8
    private static let size = NSSize(width: 18, height: 22)

    static func frames(scale: CGFloat) -> [NSImage] {
        (0..<frameCount).map { MenuBarRenderer.rasterize(frame($0), scale: scale) }
    }

    private static func frame(_ index: Int) -> NSImage {
        let phase = Double(index) / Double(frameCount)
        var squash = 0.0
        var lift = 0.0
        if phase < 0.375 {
            squash = sin(Double.pi * phase / 0.375)
        } else {
            let air = (phase - 0.375) / 0.625
            lift = sin(Double.pi * air) * 6
            squash = -0.55 * sin(Double.pi * air)
        }
        return NSImage(size: size, flipped: false) { _ in
            let width = CGFloat(14 * (1 + 0.16 * squash))
            let bodyHeight = CGFloat(10 * (1 - 0.24 * squash))
            let center = size.width / 2
            let left = center - width / 2
            let right = center + width / 2
            let bottom = CGFloat(3 + lift)
            let top = bottom + bodyHeight
            let corner: CGFloat = 2.5
            let body = NSBezierPath()
            body.move(to: NSPoint(x: left + corner, y: bottom))
            body.line(to: NSPoint(x: right - corner, y: bottom))
            body.curve(to: NSPoint(x: right, y: bottom + corner), controlPoint1: NSPoint(x: right, y: bottom), controlPoint2: NSPoint(x: right, y: bottom))
            body.curve(to: NSPoint(x: center, y: top), controlPoint1: NSPoint(x: right, y: bottom + bodyHeight * 0.8), controlPoint2: NSPoint(x: center + width * 0.3, y: top))
            body.curve(to: NSPoint(x: left, y: bottom + corner), controlPoint1: NSPoint(x: center - width * 0.3, y: top), controlPoint2: NSPoint(x: left, y: bottom + bodyHeight * 0.8))
            body.curve(to: NSPoint(x: left + corner, y: bottom), controlPoint1: NSPoint(x: left, y: bottom), controlPoint2: NSPoint(x: left, y: bottom))
            body.close()
            NSColor.black.setFill()
            body.fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let eyeY = bottom + bodyHeight * 0.42
            for side in [-1.0, 1.0] {
                let eyeX = center + CGFloat(side) * width * 0.17
                NSBezierPath(ovalIn: NSRect(x: eyeX - 1, y: eyeY - 1.3, width: 2, height: 2.6)).fill()
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
    }
}
