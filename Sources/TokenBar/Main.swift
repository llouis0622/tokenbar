import AppKit

@main
enum Main {
    @MainActor private static var controller: StatusController?

    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--render-preview"), flag + 1 < arguments.count {
            exit(renderPreview(to: arguments[flag + 1]) ? 0 : 1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        controller = StatusController()
        app.run()
    }

    @MainActor
    private static func renderPreview(to path: String) -> Bool {
        let scale: CGFloat = 2
        let columns: [BarColumn] = [
            .cells([BarCell(label: "C", value: "48%", widest: "100%"), BarCell(label: "G", value: "9%", widest: "100%")]),
            .cells([BarCell(label: "CPU", value: "54%", widest: "100%"), BarCell(label: "GPU", value: "51%", widest: "100%")]),
            .cells([BarCell(label: "RAM", value: "84%", widest: "100%"), BarCell(label: "DSK", value: "49%", widest: "100%")]),
            .cells([BarCell(label: "↑", value: "3.1K", widest: "999M"), BarCell(label: "↓", value: "9.2K", widest: "999M")]),
            .icon(symbol: "fanblades", values: ["3476"], widest: "9999"),
        ]
        let stats = MenuBarRenderer.rasterize(MenuBarRenderer.image(columns: columns), scale: scale)
        let frames = SlimeRenderer.frames(scale: scale)
        var strip: [NSImage] = []
        for index in [0, 2, 5] where index < frames.count {
            strip.append(MenuBarRenderer.compose(leading: frames[index], stats: stats))
        }
        guard let first = strip.first else { return false }
        let sheet = NSImage(size: NSSize(width: first.size.width, height: first.size.height * CGFloat(strip.count)), flipped: false) { _ in
            for (row, image) in strip.enumerated() {
                image.draw(in: NSRect(x: 0, y: first.size.height * CGFloat(row), width: image.size.width, height: image.size.height))
            }
            return true
        }
        guard let single = MenuBarRenderer.bitmap(first, scale: scale),
              let bitmap = MenuBarRenderer.bitmap(sheet, scale: scale),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return false }
        let coverage = MenuBarRenderer.coverage(single)
        print("size \(Int(first.size.width))x\(Int(first.size.height)) pixels \(single.pixelsWide)x\(single.pixelsHigh) coverage \(coverage.width) \(coverage.height)")
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            return false
        }
        return coverage.width > 0.9 && coverage.height > 0.75
    }
}
