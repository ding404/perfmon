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
            HStack(spacing: 7) {
                menuMetric("cpu", value: percentage(model.snapshot.cpu_percent))
                menuMetric("memorychip", value: percentage(model.snapshot.memory_percent))
                menuMetric("arrow.up.arrow.down", value: percentage(model.snapshot.swap_percent))
                menuMetric("arrow.down", value: compactRate(model.snapshot.rx_bytes_per_sec))
                menuMetric("arrow.up", value: compactRate(model.snapshot.tx_bytes_per_sec))
                menuMetric(
                    "internaldrive",
                    value: compactRate(model.snapshot.disk_read_bytes_per_sec)
                        + "/"
                        + compactRate(model.snapshot.disk_write_bytes_per_sec)
                )
            }
            .font(.caption2)
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func menuMetric(_ symbol: String, value: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
            Text(value)
        }
    }

    private func compactRate(_ bytes: UInt64) -> String {
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
}
