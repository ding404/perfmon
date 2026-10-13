import Foundation
import AppKit
import SwiftUI
import PerfmonFFI

@MainActor
final class MonitorModel: ObservableObject {
    @Published var snapshot = PerfmonSnapshot()

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
    }

    var statusText: String {
        guard snapshot.valid != 0 else { return "perfmon" }
        return String(format: "CPU %.0f%%", snapshot.cpu_percent)
    }
}

private final class FixedMenuBarTextField: NSTextField {
    private static let fixedSize = NSSize(width: 322, height: 18)

    override var intrinsicContentSize: NSSize { Self.fixedSize }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isBordered = false
        isBezeled = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        alignment = .left
        focusRingType = .none
        font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textColor = .labelColor
        cell?.wraps = false
        cell?.truncatesLastVisibleLine = false
        cell?.isScrollable = false
        cell?.alignment = .left
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
}

private struct FixedMenuBarLabel: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> FixedMenuBarTextField {
        let view = FixedMenuBarTextField(frame: NSRect(x: 0, y: 0, width: 322, height: 18))
        view.stringValue = text
        return view
    }

    func updateNSView(_ nsView: FixedMenuBarTextField, context: Context) {
        nsView.stringValue = text
    }
}

@main
struct PerformanceMonitorApp: App {
    @StateObject private var model = MonitorModel()

    var body: some Scene {
        MenuBarExtra {
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            FixedMenuBarLabel(text: menuBarSummary)
                .frame(width: 322, alignment: .leading)
        }
    }

    private var menuBarSummary: String {
        "◉\(percentage(model.snapshot.cpu_percent))\u{00A0}"
            + "▤\(percentage(model.snapshot.memory_percent))\u{00A0}"
            + "↕\(percentage(model.snapshot.swap_percent))\u{00A0}"
            + "↓\(compactRate(model.snapshot.rx_bytes_per_sec))\u{00A0}"
            + "↑\(compactRate(model.snapshot.tx_bytes_per_sec))\u{00A0}"
            + "◫\(compactRate(model.snapshot.disk_read_bytes_per_sec))/\(compactRate(model.snapshot.disk_write_bytes_per_sec))"
    }

    private func compactRate(_ bytes: UInt64) -> String {
        if bytes >= 1_099_511_627_776 {
            return String(format: "%5.1fT", min(Double(bytes) / 1_099_511_627_776.0, 999.9))
        }
        if bytes >= 1_073_741_824 {
            return String(format: "%5.1fG", min(Double(bytes) / 1_073_741_824.0, 999.9))
        }
        if bytes >= 1_048_576 {
            return String(format: "%5.1fM", min(Double(bytes) / 1_048_576.0, 999.9))
        }
        if bytes >= 1_024 {
            return String(format: "%5.1fK", min(Double(bytes) / 1_024.0, 999.9))
        }
        return String(format: "%5dB", min(bytes, 99_999))
    }

    private func percentage(_ value: Double) -> String {
        String(format: "%3.0f%%", min(max(value, 0), 999))
    }
}
