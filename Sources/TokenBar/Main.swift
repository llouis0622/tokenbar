import AppKit

@main
enum Main {
    @MainActor private static var controller: StatusController?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        controller = StatusController()
        app.run()
    }
}
