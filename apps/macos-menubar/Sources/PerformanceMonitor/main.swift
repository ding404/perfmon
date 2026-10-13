import Foundation
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

@main
struct PerformanceMonitorApp: App {
    @StateObject private var model = MonitorModel()

    var body: some Scene {
        MenuBarExtra {
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            Text(menuBarSummary)
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 322, alignment: .leading)
                .lineLimit(1)
                .clipped()
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
    }

    private var menuBarSummary: String {
        "◉\(fixed(percentage(model.snapshot.cpu_percent), width: 4))\u{00A0}"
            + "▤\(fixed(percentage(model.snapshot.memory_percent), width: 4))\u{00A0}"
            + "↕\(fixed(percentage(model.snapshot.swap_percent), width: 4))\u{00A0}"
            + "↓\(fixed(compactRate(model.snapshot.rx_bytes_per_sec), width: 6))\u{00A0}"
            + "↑\(fixed(compactRate(model.snapshot.tx_bytes_per_sec), width: 6))\u{00A0}"
            + "◫\(fixed(compactRate(model.snapshot.disk_read_bytes_per_sec), width: 6))/\(fixed(compactRate(model.snapshot.disk_write_bytes_per_sec), width: 6))"
    }

    private func compactRate(_ bytes: UInt64) -> String {
        if bytes >= 1_099_511_627_776 {
            return String(format: "%.1fT", Double(bytes) / 1_099_511_627_776.0)
        }
        if bytes >= 1_073_741_824 {
            return String(format: "%.1fG", Double(bytes) / 1_073_741_824.0)
        }
        if bytes >= 1_048_576 {
            return String(format: "%.1fM", Double(bytes) / 1_048_576.0)
        }
        if bytes >= 1_024 {
            return String(format: "%.1fK", Double(bytes) / 1_024.0)
        }
        return "\(bytes)B"
    }

    private func percentage(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private func fixed(_ value: String, width: Int) -> String {
        if value.count >= width {
            return String(value.prefix(width))
        }
        return String(repeating: "\u{00A0}", count: width - value.count) + value
    }
}
