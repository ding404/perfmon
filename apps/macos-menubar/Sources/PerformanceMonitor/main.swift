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
                .contentTransition(.identity)
                .animation(nil, value: menuBarSummary)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
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
            return String(format: "%05.1fT", min(Double(bytes) / 1_099_511_627_776.0, 999.9))
        }
        if bytes >= 1_073_741_824 {
            return String(format: "%05.1fG", min(Double(bytes) / 1_073_741_824.0, 999.9))
        }
        if bytes >= 1_048_576 {
            return String(format: "%05.1fM", min(Double(bytes) / 1_048_576.0, 999.9))
        }
        if bytes >= 1_024 {
            return String(format: "%05.1fK", min(Double(bytes) / 1_024.0, 999.9))
        }
        return String(format: "%05dB", min(bytes, 99_999))
    }

    private func percentage(_ value: Double) -> String {
        String(format: "%03.0f%%", min(max(value, 0), 999))
    }
}
