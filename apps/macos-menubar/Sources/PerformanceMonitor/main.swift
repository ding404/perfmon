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
            self?.sample()
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
        MenuBarExtra(model.statusText, systemImage: "gauge.with.dots.needle.67percent") {
            VStack(alignment: .leading, spacing: 8) {
                metric("CPU", value: String(format: "%.1f%%", model.snapshot.cpu_percent))
                metric("Memory", value: String(format: "%.1f%%", model.snapshot.memory_percent))
                metric("Swap", value: String(format: "%.1f%%", model.snapshot.swap_percent))
                metric("Wi-Fi ↓", value: formatRate(model.snapshot.rx_bytes_per_sec))
                metric("Wi-Fi ↑", value: formatRate(model.snapshot.tx_bytes_per_sec))
                Divider()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(12)
        }
    }

    private func metric(_ name: String, value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private func formatRate(_ bytes: UInt64) -> String {
        if bytes >= 1_048_576 {
            return String(format: "%.1f MB/s", Double(bytes) / 1_048_576.0)
        }
        if bytes >= 1_024 {
            return String(format: "%.1f KB/s", Double(bytes) / 1_024.0)
        }
        return "\(bytes) B/s"
    }
}
