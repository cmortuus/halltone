import AppKit
import HalltoneCore

enum AboutPanel {
    static func show() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "Halltone \(version) (\(build))"
        alert.informativeText = "Streams this Mac's audio to the Halltone app on your iPhone over your local network.\nhttps://github.com/cmortuus/halltone"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        text.string = Acknowledgements.text
        text.autoresizingMask = [.width]
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
