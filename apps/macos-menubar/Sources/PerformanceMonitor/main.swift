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
    private let statusWidth: CGFloat = 322
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
        button.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        button.alignment = .left
        button.title = summary(for: snapshot)
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

    private func summary(for snapshot: PerfmonSnapshot) -> String {
        "◉\(fixed(percentage(snapshot.cpu_percent), width: 4))\u{00A0}"
            + "▤\(fixed(percentage(snapshot.memory_percent), width: 4))\u{00A0}"
            + "↕\(fixed(percentage(snapshot.swap_percent), width: 4))\u{00A0}"
            + "↓\(fixed(compactRate(snapshot.rx_bytes_per_sec), width: 6))\u{00A0}"
            + "↑\(fixed(compactRate(snapshot.tx_bytes_per_sec), width: 6))\u{00A0}"
            + "◫\(fixed(compactRate(snapshot.disk_read_bytes_per_sec), width: 6))/\(fixed(compactRate(snapshot.disk_write_bytes_per_sec), width: 6))"
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
struct PerformanceMonitorApp: App {
    @NSApplicationDelegateAdaptor(PerformanceMonitorDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
