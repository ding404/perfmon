import Foundation
import SwiftUI
import PerfmonFFI

@MainActor
final class MonitorModel: ObservableObject {
    @Published var snapshot = PerfmonSnapshot()
    var onUpdate: (() -> Void)?

    private var handle: OpaquePointer?
    private var timer: Timer?

    init() {
        handle = perfmon_create()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
        sample()
    }

    deinit {
        timer?.invalidate()
        if let handle {
            perfmon_destroy(handle)
        }
    }

    func sample() {
        guard let handle else { return }
        var next = PerfmonSnapshot()
        guard perfmon_sample(handle, &next) != 0 else { return }
        snapshot = next
        onUpdate?()
    }

    var statusText: String {
        guard snapshot.valid != 0 else { return "perfmon" }
        return String(format: "CPU %.0f%%", snapshot.cpu_percent)
    }
}

@MainActor
final class PerformanceMonitorDelegate: NSObject, NSApplicationDelegate {
    private let statusWidth: CGFloat = 450
    private var statusItem: NSStatusItem?
    private var model: MonitorModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = MonitorModel()
        model.onUpdate = { [weak self] in
            self?.updateStatusItem()
        }
        self.model = model

        let statusItem = NSStatusBar.system.statusItem(withLength: statusWidth)
        statusItem.menu = makeMenu()
        self.statusItem = statusItem
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button, let snapshot = model?.snapshot else { return }
        let menuBarPointSize = NSFont.menuBarFont(ofSize: 0).pointSize
        button.font = NSFont.monospacedSystemFont(ofSize: menuBarPointSize, weight: .regular)
        button.alignment = .left
        button.cell?.wraps = false
        button.cell?.isScrollable = true
        button.cell?.lineBreakMode = .byClipping
        button.cell?.truncatesLastVisibleLine = false
        let font = button.font ?? NSFont.systemFont(ofSize: 13)
        let summary = attributedSummary(for: snapshot, font: font)
        button.attributedTitle = summary
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func attributedSummary(for snapshot: PerfmonSnapshot, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]

        appendSymbol("cpu", to: result, font: font)
        appendText(fixed(percentage(snapshot.cpu_percent), width: 4) + "\u{00A0}", to: result, attributes: attributes)
        appendSymbol("memorychip", to: result, font: font)
        appendText(fixed(percentage(snapshot.memory_percent), width: 4) + "\u{00A0}", to: result, attributes: attributes)
        appendSymbol("arrow.triangle.2.circlepath", to: result, font: font)
        appendText(fixed(percentage(snapshot.swap_percent), width: 4) + "\u{00A0}", to: result, attributes: attributes)
        appendSymbol("wifi", to: result, font: font)
        appendText("↓" + fixed(compactRate(snapshot.rx_bytes_per_sec), width: 6) + " ↑" + fixed(compactRate(snapshot.tx_bytes_per_sec), width: 6) + "\u{00A0}", to: result, attributes: attributes)
        appendSymbol("internaldrive", to: result, font: font)
        appendText(fixed(compactRate(snapshot.disk_read_bytes_per_sec), width: 6) + "/" + fixed(compactRate(snapshot.disk_write_bytes_per_sec), width: 6), to: result, attributes: attributes)
        return result
    }

    private func appendSymbol(_ name: String, to result: NSMutableAttributedString, font: NSFont) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: name)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        guard let image else { return }
        let symbolPointSize = font.pointSize * 1.2
        let configuration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
        let configuredImage = image.withSymbolConfiguration(configuration) ?? image
        let attachment = NSTextAttachment()
        attachment.image = configuredImage
        attachment.bounds = NSRect(x: 0, y: -2, width: symbolPointSize, height: symbolPointSize)
        result.append(NSAttributedString(attachment: attachment))
    }

    private func appendText(_ text: String, to result: NSMutableAttributedString, attributes: [NSAttributedString.Key: Any]) {
        result.append(NSAttributedString(string: text, attributes: attributes))
    }

    private func compactRate(_ bytes: UInt64) -> String {
        if bytes >= 1_099_511_627_776 { return String(format: "%.1fT", Double(bytes) / 1_099_511_627_776.0) }
        if bytes >= 1_073_741_824 { return String(format: "%.1fG", Double(bytes) / 1_073_741_824.0) }
        if bytes >= 1_048_576 { return String(format: "%.1fM", Double(bytes) / 1_048_576.0) }
        if bytes >= 1_024 { return String(format: "%.1fK", Double(bytes) / 1_024.0) }
        return "\(bytes)B"
    }

    private func percentage(_ value: Double) -> String { String(format: "%.0f%%", value) }

    private func fixed(_ value: String, width: Int) -> String {
        if value.count >= width { return String(value.prefix(width)) }
        return String(repeating: "\u{00A0}", count: width - value.count) + value
    }
}

@main
struct PerformanceMonitorApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = PerformanceMonitorDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
